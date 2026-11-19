package receiptparse

import (
	"math"
	"strings"
)

// Cok sayfali (uzun) fislerde sayfa metinlerini tek fis metnine birlestirir.
//
// Sayfalar arasi cakisan satirlar YALNIZCA en az 2 ardisik satir cakisiyorsa silinir: BIM gibi
// fislerde mesru bitisik tekrarlar vardir (PAT.CIPSI x2, MANTI x2) ve dikis bunlarin arasina
// denk gelebilir. Tek satirlik cakisma korunur; gercek cift okumayi reconcileItems toplamla
// dogrulayip temizler.
const (
	seamMaxOverlap = 6 // dikiste aranacak en fazla cakisan satir sayisi
	seamMinOverlap = 2 // bu kadar ardisik satir cakismadikca hicbir sey silinmez
)

func MergePageTexts(pages []string) string {
	var merged []string
	for _, p := range pages {
		lines := splitLines(p)
		if len(lines) == 0 {
			continue
		}
		if len(merged) > 0 {
			lines = lines[seamOverlap(merged, lines):]
		}
		merged = append(merged, lines...)
	}
	return strings.Join(merged, "\n")
}

// seamOverlap, sonraki sayfadan atilacak bas satir sayisini dondurur (0 = cakisma yok).
// Onceki metnin son k satiri ile sonraki metnin k satiri (bulanik) ayniysa k >= seamMinOverlap
// olmak uzere cakisma vardir. Fotograf bir satirin ortasindan kesildiyse sonraki sayfanin ILK
// satiri yarim (parca) kalir; bu yuzden o parca satir atlanarak da eslesme aranir ve parca satir
// ile birlikte atilir.
func seamOverlap(prev, next []string) int {
	bestDrop, bestK := 0, 0
	for skip := 0; skip <= 1; skip++ {
		maxK := seamMaxOverlap
		if len(prev) < maxK {
			maxK = len(prev)
		}
		if len(next)-skip < maxK {
			maxK = len(next) - skip
		}
		for k := maxK; k >= seamMinOverlap && k > bestK; k-- {
			ok := true
			for i := 0; i < k; i++ {
				if !fuzzyLineEqual(prev[len(prev)-k+i], next[skip+i]) {
					ok = false
					break
				}
			}
			if ok {
				bestDrop, bestK = skip+k, k
				break
			}
		}
	}
	return bestDrop
}

const (
	seamJaroWinkler  = 0.92 // ayni tutarli satirlar icin Jaro-Winkler esigi
	seamCropMinChars = 6    // soldan kirpilmis satirda kalan parcanin en az harf sayisi
)

// fuzzyLineEqual, ayni satirin iki farkli fotografta okunmus halini eslestirir. Kosul iki
// parcalidir:
//
//   - Fiyat: satirdaki TUTARLAR birebir ayni olmalidir (farkli fiyatli benzer adlar asla eslesmez).
//   - Metin (biri yeterli): (1) Levenshtein mesafesi uzunlugun ~1/6'si icinde (AR0MALI/AROMALI);
//     (2) uzunluklari yakin satirlarda Jaro-Winkler >= seamJaroWinkler (bosluk/harf kaymalari);
//     (3) kadraj satirin solunu kesmis: kisa metin uzun metnin SONEKI ve tutar iceriyor
//     ("ETI KARAM GURME 50 G 1,75" / "RAM GURME 50 G 1,75").
func fuzzyLineEqual(a, b string) bool {
	fa := strings.ReplaceAll(FoldTR(a), " ", "")
	fb := strings.ReplaceAll(FoldTR(b), " ", "")
	if fa == "" || fb == "" {
		return false
	}
	amtA, amtB := amountsIn(a), amountsIn(b)
	if !sameAmounts(amtA, amtB) {
		return false
	}
	la, lb := len([]rune(fa)), len([]rune(fb))
	limit := la / 6
	if limit < 1 {
		limit = 1
	}
	if levenshtein(fa, fb) <= limit {
		return true
	}
	if min(la, lb)*5 >= max(la, lb)*4 && jaroWinkler(fa, fb) >= seamJaroWinkler {
		return true
	}
	if len(amtA) > 0 {
		short, long := fa, fb
		if lb < la {
			short, long = fb, fa
		}
		if strings.HasSuffix(long, short) && countLetters(short) >= seamCropMinChars {
			return true
		}
	}
	return false
}

func sameAmounts(a, b []float64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if math.Abs(a[i]-b[i]) > 0.005 {
			return false
		}
	}
	return true
}
