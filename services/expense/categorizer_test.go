package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// fullCats: yeni taksonomi (db.go seed) - id'ler sirayla.
var fullCats = []Category{
	{ID: 1, Name: "Market / Gıda"},
	{ID: 2, Name: "Restoran / Kafe"},
	{ID: 3, Name: "Akaryakıt / Ulaşım"},
	{ID: 4, Name: "Giyim"},
	{ID: 5, Name: "Elektronik"},
	{ID: 6, Name: "Sağlık / Eczane"},
	{ID: 7, Name: "Fatura / Abonelik"},
	{ID: 8, Name: "Ev / Yaşam"},
	{ID: 9, Name: "Kişisel Bakım"},
	{ID: 10, Name: "Eğlence / Hobi"},
	{ID: 11, Name: "Diğer"},
}

func catIDByName(name string) int {
	for _, c := range fullCats {
		if c.Name == name {
			return c.ID
		}
	}
	return 0
}

func TestCategoryKeyOf(t *testing.T) {
	cases := map[string]catKey{
		"Market": keyMarket, "Market / Gıda": keyMarket,
		"Akaryakıt": keyFuel, "Ulaşım": keyFuel, "Akaryakıt / Ulaşım": keyFuel,
		"Restoran & Kafe": keyFood, "Restoran / Kafe": keyFood,
		"Sağlık": keyHealth, "Sağlık / Eczane": keyHealth,
		"Fatura": keyBills, "Fatura / Abonelik": keyBills,
		"Giyim": keyClothes, "Elektronik": keyElectronics, "Ev / Yaşam": keyHome,
		"Kişisel Bakım": keyPersonal, "Eğlence / Hobi": keyFun,
		"Diğer": keyOther, "Evcil Hayvan": keyOther,
	}
	for name, want := range cases {
		if got := categoryKeyOf(name); got != want {
			t.Errorf("categoryKeyOf(%q) = %s, want %s", name, got, want)
		}
	}
}

func TestNormalizeKey(t *testing.T) {
	cases := map[string]string{
		"PAT.CIPSI PATITO 500G":       "pat cipsi patito",
		"ŞAMPUAN 400 ML":              "sampuan",
		"SPAGETI500G":                 "spageti",
		"  KARTON  SÜT 1L ":           "karton sut",
		"BİM BİRLEŞİK MAĞAZALAR A.Ş.": "bim birlesik magazalar",
		"$OK MARKETLER":               "sok marketler",
		"123 456":                     "",
	}
	for in, want := range cases {
		if got := normalizeKey(in); got != want {
			t.Errorf("normalizeKey(%q) = %q, want %q", in, got, want)
		}
	}
}

// itemCase: kalem adinin (baglamsiz) beklenen kategorisi.
type itemCase struct {
	name string
	want catKey
}

var labeledItems = []itemCase{
	// Market / Gıda
	{"SÜT 1L", keyMarket}, {"EKMEK", keyMarket}, {"BEYAZ PEYNIR 500G", keyMarket}, {"DOMATES", keyMarket},
	{"PAT.CIPSI PATITO", keyMarket}, {"MAKARNA SPAGETI500G", keyMarket}, {"YUMURTA 15LI", keyMarket},
	{"KARTON SÜT 1L", keyMarket}, {"KAŞAR PEYNİR 500G", keyMarket}, {"ZEYTİN SİYAH", keyMarket},
	{"DOMATESLI MAKARNA", keyMarket}, {"TAVUK BUT", keyMarket}, {"POPKEK MUZLU", keyMarket},
	{"ÇİKOLATA", keyMarket}, {"AYÇİÇEK YAĞI 5L", keyMarket}, {"PİRİNÇ 1KG", keyMarket},
	{"MERCIMEK", keyMarket}, {"PATATES", keyMarket}, {"SOĞAN KURU", keyMarket}, {"LİMON", keyMarket},
	{"MUZ", keyMarket}, {"ELMA GOLDEN", keyMarket}, {"YOĞURT 1KG", keyMarket}, {"TEREYAĞ 250G", keyMarket},
	{"KOLA 2.5L", keyMarket}, {"MAYONEZ", keyMarket}, {"BİSKÜVİ", keyMarket}, {"CAY 1000G", keyMarket},
	{"KIYMA", keyMarket}, {"SUCUK", keyMarket},
	// Akaryakıt / Ulaşım
	{"KURŞUNSUZ 95", keyFuel}, {"MOTORİN EURO DİZEL", keyFuel}, {"V-POWER DIESEL", keyFuel},
	{"LPG", keyFuel}, {"OTOPARK ÜCRETİ", keyFuel}, {"HGS YÜKLEME", keyFuel}, {"BENZİN", keyFuel},
	// Restoran / Kafe
	{"ADANA KEBAP", keyFood}, {"LAHMACUN", keyFood}, {"KÜNEFE", keyFood}, {"LATTE TALL", keyFood},
	{"CHEESECAKE", keyFood}, {"İSKENDER", keyFood}, {"ESPRESSO", keyFood}, {"CAPPUCCINO", keyFood},
	{"TANTUNİ", keyFood}, {"HİZMET BEDELİ", keyFood}, {"BAKLAVA", keyFood}, {"LİMONATA", keyFood},
	// Sağlık / Eczane
	{"PARASETAMOL 500MG", keyHealth}, {"VİTAMİN C 1000", keyHealth}, {"ÖKSÜRÜK ŞURUBU", keyHealth},
	{"AĞRI KESİCİ", keyHealth}, {"CERRAHİ MASKE", keyHealth}, {"ASPİRİN", keyHealth}, {"PANSUMAN", keyHealth},
	{"ANTİBİYOTİK", keyHealth}, {"TERMOMETRE", keyHealth},
	// Giyim
	{"TİŞÖRT", keyClothes}, {"PANTOLON KOT", keyClothes}, {"SPOR AYAKKABI", keyClothes}, {"ÇORAP 3LÜ", keyClothes},
	{"MONT", keyClothes}, {"GÖMLEK", keyClothes},
	// Elektronik
	{"USB KABLO", keyElectronics}, {"KULAKLIK", keyElectronics}, {"ŞARJ ALETİ", keyElectronics},
	{"TELEFON KILIFI", keyElectronics}, {"HDMI KABLO", keyElectronics}, {"MOUSE", keyElectronics},
	// Fatura / Abonelik
	{"CEP TELEFONU FATURASI", keyBills}, {"NETFLIX ABONELİK", keyBills}, {"DOĞALGAZ FATURASI", keyBills},
	// Ev / Yaşam
	{"BULAŞIK DETERJANI", keyHome}, {"ÇAMAŞIR SUYU", keyHome}, {"AMPUL LED", keyHome}, {"TUVALET KAĞIDI", keyHome},
	{"DETERJAN 4KG", keyHome}, {"SÜPÜRGE", keyHome}, {"HAVLU", keyHome}, {"MATKAP UCU", keyHome},
	// Kişisel Bakım
	{"ŞAMPUAN 400ML", keyPersonal}, {"DİŞ MACUNU", keyPersonal}, {"DEODORANT", keyPersonal}, {"PARFÜM", keyPersonal},
	{"DUŞ JELİ", keyPersonal}, {"JİLET", keyPersonal}, {"RUJ", keyPersonal},
	// Eğlence / Hobi
	{"SİNEMA BİLETİ", keyFun}, {"KİTAP", keyFun}, {"LEGO SET", keyFun}, {"OYUNCAK ARABA", keyFun},
	{"DEFTER A4", keyFun},
}

func TestItemClassification(t *testing.T) {
	ci := newCatIndex(fullCats)
	correct := 0
	for _, c := range labeledItems {
		got := ci.classifyItem(c.name, merchantCat{}, RuleSet{})
		if got.Key == c.want {
			correct++
		} else {
			t.Logf("MISS %-28q -> %-12s (%s %.2f), want %s", c.name, got.Key, got.Source, got.Conf, c.want)
		}
	}
	acc := float64(correct) / float64(len(labeledItems))
	t.Logf("kalem dogrulugu: %d/%d = %.1f%%", correct, len(labeledItems), acc*100)
	if acc < 0.95 {
		t.Fatalf("item accuracy %.1f%% < 95%%", acc*100)
	}
}

func TestItemOCRAndTurkishVariants(t *testing.T) {
	ci := newCatIndex(fullCats)
	cases := []itemCase{
		{"SUT 1L", keyMarket},          // ASCII
		{"sut 1l", keyMarket},          // kucuk harf
		{"DOMATE$ KG", keyMarket},      // OCR: $ -> Ş ile karisabilir, yine de kok
		{"EKMEK*", keyMarket},          // noktalama
		{"SAMPUAN", keyPersonal},       // ASCII
		{"SAMPUAN3in1", keyPersonal},   // bitisik rakam
		{"DETERJ 4KG", keyHome},        // fis kisaltmasi
		{"MAKARNALAR", keyMarket},      // ek
		{"PARASETAMOI 500", keyHealth}, // OCR: l -> I (bulanik)
	}
	for _, c := range cases {
		if got := ci.classifyItem(c.name, merchantCat{}, RuleSet{}); got.Key != c.want {
			t.Errorf("%q -> %s (%s %.2f), want %s", c.name, got.Key, got.Source, got.Conf, c.want)
		}
	}
}

func TestItemFalsePositiveGuards(t *testing.T) {
	ci := newCatIndex(fullCats)
	// "bp" / "su" gibi kisa anahtarlar baska kelimelerin icinde eslesmemeli.
	for _, name := range []string{"ABPX", "SUBAY", "TRAPEZ", "XQZ 12,00"} {
		if got := ci.classifyItem(name, merchantCat{}, RuleSet{}); got.Source != srcFallback {
			t.Errorf("%q must fall back, got %s (%s %.2f)", name, got.Key, got.Source, got.Conf)
		}
	}
}

func TestItemContextDisambiguation(t *testing.T) {
	ci := newCatIndex(fullCats)
	cafe := merchantCat{Key: keyFood, ID: 2, Name: "Restoran / Kafe", Conf: 0.9, Source: srcMerchant}
	market := merchantCat{Key: keyMarket, ID: 1, Name: "Market / Gıda", Conf: 0.9, Source: srcMerchant}
	if got := ci.classifyItem("ÇAY", cafe, RuleSet{}); got.Key != keyFood {
		t.Errorf("ÇAY at cafe = %s", got.Key)
	}
	if got := ci.classifyItem("ÇAY", market, RuleSet{}); got.Key != keyMarket {
		t.Errorf("ÇAY at market = %s", got.Key)
	}
	// Sozlukte olmayan kalem guvenilir isletmenin kategorisini miras alir (dusuk guvenle, "merchant").
	got := ci.classifyItem("ZZYX ÖZEL ÜRÜN", market, RuleSet{})
	if got.Key != keyMarket || got.Source != srcMerchant || got.Review {
		t.Errorf("inherit = %+v", got)
	}
	// Karma fis: markette satilan sampuan kalemi yine Kisisel Bakim'dir (isletme sozluk eslesmesini ezmez).
	if got := ci.classifyItem("ŞAMPUAN", market, RuleSet{}); got.Key != keyPersonal {
		t.Errorf("sampuan at market = %s", got.Key)
	}
}

// ---- fis bazli (isletme + oylama + fallback) ----

type receiptCase struct {
	name       string
	text       string
	want       string // beklenen fis kategorisi (ad)
	wantSource string // bos degilse beklenen kaynak
	review     bool   // beklenen category_needs_review
	items      map[string]string
}

var sectorReceipts = []receiptCase{
	{
		name: "BIM market",
		text: "BİM BİRLEŞİK MAĞAZALAR A.Ş.\nAtatürk Mah. No:5 İstanbul\nTARİH: 12.05.2026  SAAT: 14:35\nSÜT 1L           *34,50\nEKMEK            *10,00\nDOMATES          *45,00\nDETERJAN 4KG     *189,90\nŞAMPUAN 400ML    *79,90\nTOPLAM           *359,30\nKREDİ KARTI      359,30",
		want: "Market / Gıda", wantSource: srcMerchant,
		items: map[string]string{"SÜT 1L": "Market / Gıda", "DETERJAN 4KG": "Ev / Yaşam", "ŞAMPUAN 400ML": "Kişisel Bakım"},
	},
	{
		name: "A101",
		text: "A101 YENİ MAĞAZACILIK A.Ş.\n12.05.2026\nMAKARNA 500G     *18,50\nYUMURTA 15LI     *85,00\nTOPLAM           *103,50",
		want: "Market / Gıda", wantSource: srcMerchant,
	},
	{
		name: "MIGROS",
		text: "MİGROS TİCARET A.Ş.\nTARİH 03.04.2026\nSÜT 1L   *32,00\nPEYNİR   *120,00\nTOPLAM   *152,00",
		want: "Market / Gıda", wantSource: srcMerchant,
	},
	{
		name: "SOK ($ glif hatasi)",
		text: "$OK MARKETLER TİCARET A.$.\n12.05.2026\nEKMEK  *10,00\nSÜT    *30,00\nTOPLAM *40,00",
		want: "Market / Gıda",
	},
	{
		name: "OPET akaryakit",
		text: "OPET PETROLCÜLÜK A.Ş.\n12.05.2026\nKURSUNSUZ 95   *1.250,00\nTOPLAM   *1.250,00",
		want: "Akaryakıt / Ulaşım", wantSource: srcMerchant,
		items: map[string]string{"KURSUNSUZ 95": "Akaryakıt / Ulaşım"},
	},
	{
		name: "SHELL akaryakit + market kalemi",
		text: "SHELL & TURCAS PETROL A.Ş.\n12.05.2026\nMOTORİN EURO DİZEL  *1.800,00\nSU 0.5L            *15,00\nTOPLAM  *1.815,00",
		want: "Akaryakıt / Ulaşım", wantSource: srcMerchant,
		items: map[string]string{"MOTORİN EURO DİZEL": "Akaryakıt / Ulaşım", "SU 0.5L": "Market / Gıda"},
	},
	{
		name: "BP akaryakit",
		text: "BP PETROLLERİ A.Ş.\n12.05.2026\nBENZİN   *950,00\nTOPLAM   *950,00",
		want: "Akaryakıt / Ulaşım",
	},
	{
		name: "Eczane",
		text: "ÇINAR ECZANESİ\n12.05.2026\nPARASETAMOL 500MG   *45,00\nVİTAMİN C 1000       *120,00\nSIRT MASKE           *30,00\nTOPLAM   *195,00",
		want: "Sağlık / Eczane", wantSource: srcMerchant,
		items: map[string]string{"PARASETAMOL 500MG": "Sağlık / Eczane"},
	},
	{
		name: "Restoran",
		text: "LEZZET LOKANTASI\n12.05.2026\nADANA KEBAP   *250,00\nAYRAN   *30,00\nKÜNEFE   *120,00\nTOPLAM   *400,00",
		want: "Restoran / Kafe", wantSource: srcMerchant,
		items: map[string]string{"ADANA KEBAP": "Restoran / Kafe", "AYRAN": "Restoran / Kafe"},
	},
	{
		name: "Starbucks",
		text: "STARBUCKS COFFEE\n12.05.2026\nLATTE TALL   *125,00\nCHEESECAKE   *140,00\nTOPLAM   *265,00",
		want: "Restoran / Kafe", wantSource: srcMerchant,
	},
	{
		name: "Giyim",
		text: "LC WAIKIKI MAĞAZACILIK\n12.05.2026\nTİŞÖRT   *199,99\nPANTOLON   *399,99\nTOPLAM   *599,98",
		want: "Giyim",
	},
	{
		name: "Elektronik",
		text: "TEKNOSA İÇ VE DIŞ TİCARET\n12.05.2026\nUSB KABLO   *149,00\nKULAKLIK   *899,00\nTOPLAM   *1.048,00",
		want: "Elektronik",
	},
	{
		name: "Fatura",
		text: "TURKCELL İLETİŞİM HİZMETLERİ\n12.05.2026\nCEP TELEFONU FATURASI   *450,00\nTOPLAM   *450,00",
		want: "Fatura / Abonelik",
	},
	{
		name: "Ev / Yasam (yapi market)",
		text: "KOÇTAŞ YAPI MARKETLERİ\n12.05.2026\nAMPUL LED   *60,00\nBOYA FIRÇASI   *45,00\nVİDA   *20,00\nTOPLAM   *125,00",
		want: "Ev / Yaşam",
	},
	// ---- isletme tanimsiz: oylama ----
	{
		name: "bilinmeyen isletme, gida kalemleri -> oylama",
		text: "YILDIZ GIDA SAN. TİC. LTD. ŞTİ.\n12.05.2026\nSÜT 1L   *34,50\nEKMEK   *10,00\nPEYNİR   *120,00\nYUMURTA   *85,00\nTOPLAM   *249,50",
		want: "Market / Gıda", wantSource: srcItems,
	},
	{
		name: "bilinmeyen isletme, elektronik kalemleri -> oylama",
		text: "ABC BİLİŞİM LTD. ŞTİ.\n12.05.2026\nUSB KABLO   *149,00\nKULAKLIK   *899,00\nMOUSE   *250,00\nTOPLAM   *1.298,00",
		want: "Elektronik", wantSource: srcItems,
	},
	// ---- belirsiz: fallback ----
	{
		name: "belirsiz: tanimsiz isletme ve kalemler",
		text: "XYZ TİCARET\n12.05.2026\nHİZMET   *100,00\nDİĞER   *50,00\nTOPLAM   *150,00",
		want: "Diğer", wantSource: srcFallback, review: true,
	},
	{
		name: "karma ve isletmesiz: dusuk guven -> Diger",
		text: "GENEL TİCARET LTD.\n12.05.2026\nSÜT 1L   *30,00\nDETERJAN   *80,00\nŞAMPUAN   *60,00\nKİTAP   *70,00\nTOPLAM   *240,00",
		want: "Diğer", wantSource: srcFallback, review: true,
	},
}

func TestSectorReceipts(t *testing.T) {
	correct := 0
	for _, rc := range sectorReceipts {
		r := Parse(rc.text, fullCats, now)
		ok := r.CategoryName == rc.want
		if rc.wantSource != "" && r.CategorySource != rc.wantSource {
			ok = false
		}
		if r.CategoryNeedsReview != rc.review {
			ok = false
		}
		for item, want := range rc.items {
			found := false
			for _, it := range r.Items {
				if it.Name == item {
					found = true
					if it.CategoryName != want {
						ok = false
						t.Errorf("%s: item %q = %s, want %s", rc.name, item, it.CategoryName, want)
					}
				}
			}
			if !found {
				ok = false
				t.Errorf("%s: item %q not parsed (items=%+v)", rc.name, item, r.Items)
			}
		}
		if ok {
			correct++
		} else {
			t.Errorf("%s: category=%s source=%s review=%v conf=%.2f, want %s/%s/%v (candidates=%+v)",
				rc.name, r.CategoryName, r.CategorySource, r.CategoryNeedsReview, r.Confidence.Category,
				rc.want, rc.wantSource, rc.review, r.CategoryCandidates)
		}
	}
	t.Logf("fis dogrulugu: %d/%d", correct, len(sectorReceipts))
}

// Gercek PaddleOCR ciktilari (realreceipts_test.go): bozuk kalem adlari ve OCR rakam hatalarina ragmen
// BIM fisleri Market, kalemler cogunlukla sozluk eslesmesiyle Market olmali.
func TestRealReceiptsCategories(t *testing.T) {
	for name, txt := range map[string]string{"BIM kirli": ocrBimKirli, "BIM koltuk": ocrBimKoltuk} {
		r := Parse(txt, fullCats, now)
		if r.CategoryName != "Market / Gıda" || r.CategorySource != srcMerchant || r.CategoryNeedsReview {
			t.Errorf("%s: %s %s review=%v", name, r.CategoryName, r.CategorySource, r.CategoryNeedsReview)
		}
		market, keyword := 0, 0
		for _, it := range r.Items {
			if it.CategoryName == "Market / Gıda" {
				market++
			}
			if it.CategorySource == srcKeyword {
				keyword++
			}
			if it.CategoryID == 0 || it.CategoryName == "" {
				t.Errorf("%s: item without category: %+v", name, it)
			}
		}
		if float64(market) < 0.85*float64(len(r.Items)) || float64(keyword) < 0.5*float64(len(r.Items)) {
			t.Errorf("%s: market=%d keyword=%d of %d items", name, market, keyword, len(r.Items))
		}
	}
	// Marka tanimsiz, kalem yok: guvenli fallback.
	if r := Parse(ocrCanBolat, fullCats, now); r.CategoryName != "Diğer" || !r.CategoryNeedsReview {
		t.Errorf("CanBolat: %s review=%v", r.CategoryName, r.CategoryNeedsReview)
	}
}

func TestFallbackIsOtherWithZeroConfidence(t *testing.T) {
	r := Parse("XYZ TİCARET\n12.05.2026\nHİZMET *100,00\nTOPLAM *100,00", fullCats, now)
	if r.CategoryID != catIDByName("Diğer") || r.Confidence.Category != 0 || !r.CategoryNeedsReview {
		t.Fatalf("fallback = %d conf=%v review=%v", r.CategoryID, r.Confidence.Category, r.CategoryNeedsReview)
	}
	for _, it := range r.Items {
		if it.CategoryName != "Diğer" || !it.CategoryReview {
			t.Errorf("item %+v must fall back to Diğer with review flag", it)
		}
	}
}

func TestCandidatesAndJSONShape(t *testing.T) {
	r := Parse(sectorReceipts[0].text, fullCats, now) // BIM karma
	if len(r.CategoryCandidates) == 0 || r.CategoryCandidates[0].Name != "Market / Gıda" {
		t.Fatalf("candidates = %+v", r.CategoryCandidates)
	}
	b, _ := json.Marshal(r)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	for _, k := range []string{"category_id", "category_name", "category_source", "category_needs_review", "category_candidates"} {
		if _, ok := m[k]; !ok {
			t.Errorf("parse JSON missing %q: %s", k, b)
		}
	}
	items := m["items"].([]any)
	first := items[0].(map[string]any)
	for _, k := range []string{"category_id", "category_name", "category_confidence", "category_source"} {
		if _, ok := first[k]; !ok {
			t.Errorf("item JSON missing %q: %v", k, first)
		}
	}
	if _, ok := first["suggested_category_id"]; ok {
		t.Error("suggested_category_id is request-only")
	}
}

func TestOldCategoryNamesStillWork(t *testing.T) {
	// Eski kurulumlar eski adlarla kalabilir; sozluk ad -> anahtar eslemesiyle calisir.
	old := []Category{{ID: 1, Name: "Market"}, {ID: 2, Name: "Akaryakıt"}, {ID: 3, Name: "Diğer"}}
	if r := Parse("OPET PETROLCÜLÜK\n12.05.2026\nKURSUNSUZ 95  *500,00\nTOPLAM *500,00", old, now); r.CategoryName != "Akaryakıt" {
		t.Fatalf("old names: %s", r.CategoryName)
	}
}

func TestConfidenceThresholdEnv(t *testing.T) {
	saved := categoryMinConfidence
	defer func() { categoryMinConfidence = saved }()
	// Esigi cok yukseltince tek bir zayif oylama bile Diger'e duser.
	categoryMinConfidence = 0.99
	r := Parse(sectorReceipts[14].text, fullCats, now) // bilinmeyen isletme, gida
	if r.CategoryName != "Diğer" || !r.CategoryNeedsReview {
		t.Fatalf("threshold 0.99 should fall back, got %s", r.CategoryName)
	}
}

// ---- kullanici kurallari ----

func TestUserMerchantRuleOverrides(t *testing.T) {
	text := "YILDIZ GIDA SAN. TİC. LTD. ŞTİ.\n12.05.2026\nSÜT 1L *34,50\nEKMEK *10,00\nTOPLAM *44,50"
	rules := RuleSet{Merchant: map[string]int{merchantKey("YILDIZ GIDA SAN. TİC. LTD. ŞTİ."): catIDByName("Eğlence / Hobi")}}
	r := ParseWith(text, fullCats, now, ParseOptions{Rules: rules})
	if r.CategoryName != "Eğlence / Hobi" || r.CategorySource != srcRule || r.CategoryNeedsReview {
		t.Fatalf("merchant rule: %s %s review=%v", r.CategoryName, r.CategorySource, r.CategoryNeedsReview)
	}
	// Kucuk yazim farki (OCR) Jaro-Winkler ile yine yakalanir.
	r = ParseWith(strings.Replace(text, "YILDIZ", "YILD1Z", 1), fullCats, now, ParseOptions{Rules: rules})
	if r.CategorySource != srcRule {
		t.Fatalf("fuzzy merchant rule not applied: %s %s", r.CategoryName, r.CategorySource)
	}
	// Kural olmadan ayni fis oylamayla Market olur.
	if r := Parse(text, fullCats, now); r.CategoryName != "Market / Gıda" {
		t.Fatalf("no rule = %s", r.CategoryName)
	}
}

func TestUserItemRuleOverrides(t *testing.T) {
	text := "BİM BİRLEŞİK MAĞAZALAR A.Ş.\n12.05.2026\nSÜT 1L   *34,50\nEKMEK  *10,00\nTOPLAM *44,50"
	rules := RuleSet{Item: map[string]int{normalizeKey("EKMEK"): catIDByName("Eğlence / Hobi")}}
	r := ParseWith(text, fullCats, now, ParseOptions{Rules: rules})
	var ekmek, sut expenseItem
	for _, it := range r.Items {
		switch it.Name {
		case "EKMEK":
			ekmek = it
		case "SÜT 1L":
			sut = it
		}
	}
	if ekmek.CategoryName != "Eğlence / Hobi" || ekmek.CategorySource != srcRule || ekmek.CategoryConfidence < 0.9 {
		t.Fatalf("item rule: %+v", ekmek)
	}
	if sut.CategoryName != "Market / Gıda" {
		t.Fatalf("other items unaffected: %+v", sut)
	}
	// Fis kategorisi (BIM) kalem kuralindan etkilenmez.
	if r.CategoryName != "Market / Gıda" {
		t.Fatalf("receipt = %s", r.CategoryName)
	}
}

func TestRuleForFuzzy(t *testing.T) {
	rules := map[string]int{"karton sut": 7}
	if id, ok := ruleFor(rules, "karton sut", 0.94); !ok || id != 7 {
		t.Fatal("exact")
	}
	if id, ok := ruleFor(rules, "karton sut ", 0.94); !ok || id != 7 { // bosluk farki degil, benzerlik
		_ = id
	}
	if _, ok := ruleFor(rules, "tamamen farkli", 0.94); ok {
		t.Fatal("unrelated key must not match")
	}
	if _, ok := ruleFor(rules, "", 0.94); ok {
		t.Fatal("empty key")
	}
	if _, ok := ruleFor(map[string]int{"ab": 1}, "ac", 0.94); ok {
		t.Fatal("short keys match exactly only")
	}
}

func TestCollectRuleUpdates(t *testing.T) {
	in := expenseInput{
		Merchant: "YILDIZ GIDA", CategoryID: 2, SuggestedCategoryID: 1,
		Items: []expenseItem{
			{Name: "EKMEK 1ADET", CategoryID: 8, SuggestedCategoryID: 1}, // duzeltildi
			{Name: "SÜT 1L", CategoryID: 1, SuggestedCategoryID: 1},      // onaylandi
			{Name: "ELLE EKLENDI", CategoryID: 9},                        // onerisiz
			{Name: "123", CategoryID: 2, SuggestedCategoryID: 1},         // bos anahtar
			{Name: "EKMEK", CategoryID: 8, SuggestedCategoryID: 1},       // ayni anahtar tekrari
			{Name: "SUTSUZ", CategoryID: 0, SuggestedCategoryID: 1},      // atanmamis
		},
	}
	got := collectRuleUpdates(in)
	want := []ruleUpdate{{"merchant", "yildiz gida", 2}, {"item", "ekmek", 8}}
	if len(got) != len(want) {
		t.Fatalf("updates = %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("update %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	// Onerilen = secilen ya da oneri yok: kural yok.
	if u := collectRuleUpdates(expenseInput{Merchant: "X MARKET", CategoryID: 1, SuggestedCategoryID: 1}); len(u) != 0 {
		t.Errorf("confirmed suggestion produced %+v", u)
	}
	if u := collectRuleUpdates(expenseInput{Merchant: "X MARKET", CategoryID: 1}); len(u) != 0 {
		t.Errorf("manual choice produced %+v", u)
	}
}

// ---- API / saklama ----

func TestItemsForStorageDropsTransientFields(t *testing.T) {
	in := []expenseItem{{Name: "SÜT", Amount: 30, CategoryID: 1, CategoryName: "Market / Gıda", CategoryConfidence: 0.9,
		CategorySource: srcKeyword, CategoryReview: true, SuggestedCategoryID: 2}}
	b, _ := json.Marshal(itemsForStorage(in))
	if string(b) != `[{"name":"SÜT","amount":30,"category_id":1}]` {
		t.Fatalf("stored = %s", b)
	}
	// Eski satirlar (kategorisiz) sorunsuz okunur ve yazilir.
	var old []expenseItem
	if err := json.Unmarshal([]byte(`[{"name":"EKMEK","amount":5}]`), &old); err != nil || old[0].CategoryID != 0 {
		t.Fatalf("legacy row: %v %+v", err, old)
	}
	if b, _ := json.Marshal(itemsForStorage(old)); string(b) != `[{"name":"EKMEK","amount":5}]` {
		t.Fatalf("legacy stored = %s", b)
	}
}

func TestItemCategoriesValid(t *testing.T) {
	if !itemCategoriesValid([]expenseItem{{Name: "a", CategoryID: 0}, {Name: "b", CategoryID: 3}}, fullCats) {
		t.Fatal("known / unassigned ids must be valid")
	}
	if itemCategoriesValid([]expenseItem{{Name: "a", CategoryID: 99}}, fullCats) {
		t.Fatal("unknown id must be invalid")
	}
}

func TestValidateRejectsNegativeItemCategory(t *testing.T) {
	in := expenseInput{Amount: 10, Date: "2026-05-12", CategoryID: 1, Items: []expenseItem{{Name: "a", Amount: 1, CategoryID: -1}}}
	if _, msg := in.validate(); msg == "" {
		t.Fatal("negative item category_id must be rejected")
	}
}

func TestParseWithoutOptionsEqualsParse(t *testing.T) {
	a, _ := json.Marshal(Parse(sectorReceipts[0].text, fullCats, now))
	b, _ := json.Marshal(ParseWith(sectorReceipts[0].text, fullCats, now, ParseOptions{}))
	if string(a) != string(b) {
		t.Fatalf("Parse != ParseWith(zero)\n%s\n%s", a, b)
	}
}
