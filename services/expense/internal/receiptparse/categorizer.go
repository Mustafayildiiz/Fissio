package receiptparse

import (
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// Otomatik kategorilendirme motoru (hibrit):
//  1. Kural / anahtar kelime: kullanicinin ogrenilmis kurallari > isletme markasi > urun sozlugu
//     (category_lexicon.go), Turkce karakter ve OCR bozulmalarina dayanikli.
//  2. Agirlikli oylama: isletme tanimsizsa fis kategorisi kalemlerin tutar x guven agirliklariyla secilir.
//  3. Guven skoru + fallback: skor categoryMinConfidence altindaysa "Diğer" ve inceleme bayragi.
//
// Tum fonksiyonlar saf (DB'siz); kullanici kurallari RuleSet olarak disaridan verilir.

const (
	srcRule     = "rule"     // kullanicinin onceki duzeltmesinden ogrenilen kural
	srcMerchant = "merchant" // fis basligindaki marka / isletme
	srcKeyword  = "keyword"  // yalnizca fis govdesinde zayif marka eslesmesi ya da kalem sozlugu
	srcItems    = "items"    // kalemlerin agirlikli oylamasi
	srcFallback = "fallback" // guven yetersiz: "Diğer"

	// categoryReviewBelow: bu guvenin altindaki (ama eslesen) fis kategorisi de "kontrol edin" isaretlenir.
	categoryReviewBelow = 0.65
	ruleConfidence      = 0.98
)

// categoryMinConfidence: bu guvenin altinda "Diğer"e dusulur. CATEGORY_MIN_CONFIDENCE ile degistirilebilir.
var categoryMinConfidence = 0.5

func init() {
	if v, err := strconv.ParseFloat(os.Getenv("CATEGORY_MIN_CONFIDENCE"), 64); err == nil && v > 0 && v < 1 {
		categoryMinConfidence = v
	}
}

// RuleSet kullanicinin ogrenilmis tercihleridir: NormalizeKey(desen) -> kategori id.
type RuleSet struct {
	Merchant map[string]int
	Item     map[string]int
}

// ParseOptions Parse'a istege bagli girdileri tasir (Parse = ParseWith + sifir deger).
type ParseOptions struct {
	Rules RuleSet
}

// CategoryCandidate arayuzde hizli secim icin onerilen kategoridir.
type CategoryCandidate struct {
	ID    int     `json:"id"`
	Name  string  `json:"name"`
	Score float64 `json:"score"`
}

// ---- normalizasyon ----

var unitTokens = map[string]bool{
	"g": true, "gr": true, "kg": true, "kq": true, "lt": true, "l": true, "ml": true, "cl": true,
	"adet": true, "adt": true, "ad": true, "x": true, "kdv": true,
}

// splitLetters metni harf-rakam sinirlarindan ve noktalamadan boler, yalnizca HARF token'larini
// dondurur ("SPAGETI500G" -> spageti, g; "PAT.CIPSI" -> pat, cipsi). Girdi FoldTR formunda olmali.
func splitLetters(folded string) []string {
	var toks []string
	var cur []rune
	flush := func() {
		if len(cur) > 0 {
			toks = append(toks, string(cur))
			cur = cur[:0]
		}
	}
	for _, r := range folded {
		if unicode.IsLetter(r) {
			cur = append(cur, r)
		} else {
			flush()
		}
	}
	flush()
	return toks
}

// NormalizeKey kural anahtarini uretir: Turkce karakter/harf boyutu farksiz, rakam, birim, noktalama
// ve tek harfler ayiklanmis ("PAT.CIPSI PATITO 500G" -> "pat cipsi patito"). Bos donerse kural yazilmaz.
func NormalizeKey(s string) string {
	var out []string
	for _, t := range splitLetters(FoldTR(fixTurkishGlyphs(s))) {
		if len([]rune(t)) >= 2 && !unitTokens[t] {
			out = append(out, t)
		}
	}
	return strings.Join(out, " ")
}

// MerchantKey isletme adi icin NormalizeKey'dir; ek olarak harf yerine okunan rakamlari (YILD1Z, M1GROS)
// duzeltir. Kalem adlarina uygulanmaz (SUT1L gibi birimli adlar bozulmasin).
func MerchantKey(s string) string {
	return NormalizeKey(normalizeOCR(FoldTR(fixTurkishGlyphs(s))))
}

// ---- kategori dizini ----

type catIndex struct {
	byKey map[catKey]Category
	byID  map[int]Category
	other Category
}

func newCatIndex(cats []Category) *catIndex {
	ci := &catIndex{byKey: map[catKey]Category{}, byID: map[int]Category{}, other: Category{Name: fallbackCategory}}
	foundOther := false
	for _, c := range cats {
		ci.byID[c.ID] = c
		k := categoryKeyOf(c.Name)
		if k == keyOther {
			if c.Name == fallbackCategory && !foundOther {
				ci.other, foundOther = c, true
			}
			continue
		}
		if _, ok := ci.byKey[k]; !ok {
			ci.byKey[k] = c
		}
	}
	return ci
}

// enrichCats veritabanindaki anahtar kelimelere sozluk markalarini ekler (girdiyi degistirmez).
func enrichCats(cats []Category) []Category {
	out := make([]Category, len(cats))
	for i, c := range cats {
		seen := map[string]bool{}
		var kws []string
		for _, kw := range append(append([]string{}, c.Keywords...), lexicon[categoryKeyOf(c.Name)].brands...) {
			if f := FoldTR(kw); f != "" && !seen[f] {
				seen[f] = true
				kws = append(kws, kw)
			}
		}
		c.Keywords = kws
		out[i] = c
	}
	return out
}

// ---- sozluk eslestirme ----

// scoreKeyword tek anahtar kelimeyi/ifadeyi kalem token'larina karsi puanlar (0 = eslesme yok).
// Tam token 0.9, ek toleransli onek 0.8, kisaltilmis token 0.7, bulanik (>=6 harf) 0.65.
func scoreKeyword(toks []string, joined, kw string) float64 {
	if strings.Contains(kw, " ") {
		if containsWord(joined, kw) {
			return 0.9
		}
		if fuzzyTokenMatch(joined, kw, 7) {
			return 0.65
		}
		return 0
	}
	best := 0.0
	kl := len([]rune(kw))
	for _, t := range toks {
		tl := len([]rune(t))
		var s float64
		switch {
		case t == kw:
			s = 0.9
		case kl >= 4 && strings.HasPrefix(t, kw) && tl-kl <= 4:
			s = 0.8 // "domatesli", "makarnalar"
		case tl >= 5 && strings.HasPrefix(kw, t) && kl-tl <= 3:
			s = 0.7 // fis kisaltmasi: "DETERJ" -> deterjan
		case kl >= 6 && tl >= 5 && levenshtein(t, kw) <= maxEdits(kl):
			s = 0.65
		}
		if s > best {
			best = s
		}
	}
	return best
}

// lexScores kalem adinin her kategori sozlugune gore en iyi puanini dondurur.
func (ci *catIndex) lexScores(name string) map[catKey]float64 {
	f := FoldTR(fixTurkishGlyphs(name))
	best := map[catKey]float64{}
	for _, text := range []string{f, normalizeOCR(f)} { // ikincisi: MIGR0S, 0PET gibi OCR rakam hatalari
		toks := splitLetters(text)
		joined := strings.Join(toks, " ")
		for key := range ci.byKey {
			for _, kw := range lexicon[key].items {
				if s := scoreKeyword(toks, joined, kw); s > best[key] {
					best[key] = s
				}
			}
		}
	}
	return best
}

// ---- kalem sinifi ----

type itemCat struct {
	Key    catKey
	ID     int
	Name   string
	Conf   float64
	Source string
	Review bool
}

type merchantCat struct {
	Key    catKey
	ID     int
	Name   string
	Conf   float64
	Source string
}

func (ci *catIndex) fallbackItem() itemCat {
	return itemCat{Key: keyOther, ID: ci.other.ID, Name: ci.other.Name, Source: srcFallback, Review: true}
}

// ruleFor, anahtar icin tam ya da (>= 6 harf) Jaro-Winkler >= 0.94 eslesen kurali dondurur.
func ruleFor(rules map[string]int, key string, jw float64) (int, bool) {
	if key == "" || len(rules) == 0 {
		return 0, false
	}
	if id, ok := rules[key]; ok {
		return id, true
	}
	if len([]rune(key)) < 6 {
		return 0, false
	}
	bestID, bestSim := 0, jw
	for k, id := range rules {
		if sim := jaroWinkler(key, k); sim >= bestSim {
			bestID, bestSim = id, sim
		}
	}
	return bestID, bestID != 0
}

// classifyItem bir kalemin kategorisini belirler. ctx, guvenilir isletme kategorisidir (yoksa Conf=0).
func (ci *catIndex) classifyItem(name string, ctx merchantCat, rules RuleSet) itemCat {
	if id, ok := ruleFor(rules.Item, NormalizeKey(name), 0.94); ok {
		if c, ok := ci.byID[id]; ok {
			return itemCat{Key: categoryKeyOf(c.Name), ID: c.ID, Name: c.Name, Conf: ruleConfidence, Source: srcRule}
		}
	}
	scores := ci.lexScores(name)
	var top catKey
	topS := 0.0
	for _, k := range lexiconPriority { // deterministik: esitlikte oncelik sirasi
		if s := scores[k]; s > topS {
			top, topS = k, s
		}
	}
	if topS > 0 {
		// Baglam: isletme kategorisi de eslesiyorsa ve en iyiden cok geride degilse o kazanir
		// ("CAY"/"SU" markette Market, kafede Restoran).
		if ctx.Conf >= 0.85 {
			if s := scores[ctx.Key]; s > 0 && s >= topS-0.15 {
				top, topS = ctx.Key, s
			}
		}
		conf := topS
		if ctx.Conf < 0.85 || top != ctx.Key {
			for _, k := range lexiconPriority { // baska kategoriyle neredeyse berabere: belirsiz
				if k != top && scores[k] > 0 && math.Abs(scores[k]-topS) < 0.05 {
					conf -= 0.2
					break
				}
			}
		}
		c := ci.byKey[top]
		return itemCat{Key: top, ID: c.ID, Name: c.Name, Conf: round2(conf), Source: srcKeyword}
	}
	// Sozlukte yok: guvenilir bir isletme varsa onun kategorisini miras al (dusuk guvenle).
	if ctx.Conf >= 0.85 && ctx.Key != "" && ctx.Key != keyOther {
		return itemCat{Key: ctx.Key, ID: ctx.ID, Name: ctx.Name, Conf: 0.6, Source: srcMerchant}
	}
	return ci.fallbackItem()
}

// ---- isletme (fis) sinifi ----

// classifyMerchant isletme kategorisini belirler: kullanici kurali > baslikta marka (0.9) > yalnizca
// govdede marka (0.6). Anahtar kelimeler enrichCats ile sozlugu icerir.
func (ci *catIndex) classifyMerchant(cats []Category, header, all []string, merchant string, rules RuleSet) merchantCat {
	if id, ok := ruleFor(rules.Merchant, MerchantKey(merchant), 0.93); ok {
		if c, ok := ci.byID[id]; ok {
			return merchantCat{Key: categoryKeyOf(c.Name), ID: c.ID, Name: c.Name, Conf: ruleConfidence, Source: srcRule}
		}
	}
	headerText := FoldTR(strings.Join(header, "\n"))
	allText := FoldTR(strings.Join(all, "\n"))
	var best Category
	bestScore := 0
	for _, c := range cats {
		score := 0
		for _, kw := range c.Keywords {
			k := FoldTR(kw)
			if containsWordFuzzy(headerText, k) {
				score += 3 // Baslikta gecen marka daha guclu sinyaldir.
			}
			if containsWordFuzzy(allText, k) {
				score++
			}
		}
		if score > bestScore {
			best, bestScore = c, score
		}
	}
	switch {
	case bestScore >= 3:
		return merchantCat{Key: categoryKeyOf(best.Name), ID: best.ID, Name: best.Name, Conf: 0.9, Source: srcMerchant}
	case bestScore > 0:
		return merchantCat{Key: categoryKeyOf(best.Name), ID: best.ID, Name: best.Name, Conf: 0.6, Source: srcKeyword}
	}
	return merchantCat{Key: keyOther, ID: ci.other.ID, Name: ci.other.Name}
}

// ---- oylama ----

type voteResult struct {
	Key    catKey
	Conf   float64
	Scores map[catKey]float64
}

// vote fisin kategorisini kalemlerden hesaplar: her kalemin agirligi tutar x guven; yalnizca bagimsiz
// kanit (sozluk/kural) sayilir, isletmeden miras alinan kalemler dislanir. conf = pay x kapsama x ort. guven
// (pay: kazanan kategorinin agirlik orani; kapsama: siniflanan tutarin toplam tutara orani).
func (ci *catIndex) vote(items []Item, cats []itemCat) voteResult {
	weight := func(i int) float64 {
		if items[i].Amount > 0 {
			return items[i].Amount
		}
		return 1
	}
	total, classified := 0.0, 0.0
	w := map[catKey]float64{}
	confW := map[catKey]float64{} // agirlik x guven toplami
	for i, ic := range cats {
		wt := weight(i)
		total += wt
		if ic.Source != srcKeyword && ic.Source != srcRule {
			continue
		}
		classified += wt
		w[ic.Key] += wt
		confW[ic.Key] += wt * ic.Conf
	}
	res := voteResult{Scores: map[catKey]float64{}}
	if classified == 0 || total == 0 {
		return res
	}
	coverage := classified / total
	for k, wt := range w {
		share := wt / classified
		avgConf := confW[k] / wt
		res.Scores[k] = round2(math.Min(0.85, share*coverage*avgConf))
	}
	for _, k := range lexiconPriority {
		if s := res.Scores[k]; s > res.Scores[res.Key] {
			res.Key = k
		}
	}
	res.Conf = res.Scores[res.Key]
	return res
}

// applyCategories kalem kategorilerini atar ve fis kategorisini (isletme + oylama) nihai olarak secer.
func (ci *catIndex) applyCategories(res *ParseResult, m merchantCat, rules RuleSet) {
	cats := make([]itemCat, len(res.Items))
	for i := range res.Items {
		ic := ci.classifyItem(res.Items[i].Name, m, rules)
		cats[i] = ic
		it := &res.Items[i]
		it.CategoryID, it.CategoryName = ic.ID, ic.Name
		it.CategoryConfidence, it.CategorySource, it.CategoryReview = ic.Conf, ic.Source, ic.Review
	}
	v := ci.vote(res.Items, cats)

	final := m
	switch {
	case m.Conf >= 0.85:
		// guvenilir isletme: kalemler farkli olsa da fis isletmeye gore kategorilenir (karma fis).
	case v.Conf > 0 && m.Conf > 0 && v.Key == m.Key:
		final.Conf = math.Min(0.95, math.Max(m.Conf, v.Conf)+0.1)
		final.Source = srcItems
	case v.Conf > m.Conf:
		c := ci.byKey[v.Key]
		final = merchantCat{Key: v.Key, ID: c.ID, Name: c.Name, Conf: v.Conf, Source: srcItems}
	}

	// Aday kategoriler (hizli secim): kazanan + oylama + isletme, puana gore en fazla 3.
	score := map[catKey]float64{}
	for k, s := range v.Scores {
		score[k] = s
	}
	if m.Conf > 0 && m.Key != keyOther && m.Conf > score[m.Key] {
		score[m.Key] = m.Conf
	}
	if final.Key != keyOther && final.Conf > score[final.Key] {
		score[final.Key] = final.Conf
	}
	var keys []catKey
	for k := range score {
		keys = append(keys, k)
	}
	sort.SliceStable(keys, func(i, j int) bool {
		if score[keys[i]] != score[keys[j]] {
			return score[keys[i]] > score[keys[j]]
		}
		return indexOfKey(keys[i]) < indexOfKey(keys[j])
	})
	for _, k := range keys {
		if c, ok := ci.byKey[k]; ok && len(res.CategoryCandidates) < 3 {
			res.CategoryCandidates = append(res.CategoryCandidates, CategoryCandidate{ID: c.ID, Name: c.Name, Score: round2(score[k])})
		}
	}

	if final.Conf < categoryMinConfidence {
		res.CategoryID, res.CategoryName = ci.other.ID, ci.other.Name
		res.Confidence.Category, res.CategorySource, res.CategoryNeedsReview = 0, srcFallback, true
		return
	}
	res.CategoryID, res.CategoryName = final.ID, final.Name
	res.Confidence.Category = round2(final.Conf)
	res.CategorySource = final.Source
	res.CategoryNeedsReview = final.Conf < categoryReviewBelow
}

func indexOfKey(k catKey) int {
	for i, p := range lexiconPriority {
		if p == k {
			return i
		}
	}
	return len(lexiconPriority)
}
