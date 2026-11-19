package receiptparse

import (
	"strings"
	"testing"
)

// Aşağıdaki metinler gerçek fiş fotoğraflarının PaddleOCR çıktılarıdır (hataları dahil):
// kayan sütunlar, etiketle yapışık tarih, KDU/TOP etiketleri, adet satırları, "%08 *" kalıntıları.

const ocrBimKirli = `/05445020217 BIRLESIK MAGAZALAR A.S BIM
KEMALPASA MH.MOLLA YAKUP SOK
NO:3/A MERKEZCANAKKALE
1750051846
BUYUKMUKELLEFLER
TARIH 04/09/2021
TARIF SAAT 17:43:33
SAAT FISNO 0468
FIS MANTI 450GMUTFAGIM %08 3.95
GOF MANTI 450 G MUTFAGIM %08 3.95
B1S SCHNITZEL700 G %08 13.90
AL MISIR CIPSI 300 G %08 6.50
YU DOND.PATATES10O0G %08 069
MI D0ND.PATATES1000G 80% 6.90
Y PAT.CIPS1150G/135G %08 4.50
MAKARNA SPAGETI500G 808 2.50
MAKARNA SPAGET1500G 808 2.50
MEYVE NEKT.VISNE ILT 80% 4.50
MADENSUYU6x200ML %08 5.90
TIRAS BICAG!6LI %18 4.50
SUCUK PILIC400 G %08 10.50
NUGGET300G %08 7.90
4AdtX0.90
GOFRET CIKOLATAL136G %08 3.60
KOFTE PISMIS 250G %08 11.90
PILIC KOFTE 300 GR %08 7. 90
BALDOTRINC1KG %08 +12. 25
3A0.25 ALISVERISPOSET %18 0.75
TOPKDY 223.65 16,98
TOPLAM
NAKIT
PARAUSTU *225.00
1.35
lyi gonler.yine bekleri2
POS:003/K.KODU193918 KASIYERCC
MERSIS0175005184608645`

const ocrBimKoltuk = `BIM BIRLESIK MAGAZALAR A.S
HARMANMH.MEZARLIKSK.NO4
TALAS/KAYSER
B0Y0K M0KELLEFLER V.D1750051846
TARIH12.12.2019
SAAT 17:57
FIS NO0298
PAT.CIPSI PATITO %08 3,25
PAT.CIPSI PATITO %08 3,25
SOT AROMALI %08 1,00
ETI KARAM GURME 50 G %08 1,75
ETIKARAM GURME 50 G %08 1,75
200ML.MUZ.S0T %08 1,00
SUT AROMALI %08 1,00
200ML.MUZ.ST %08 1,00
SUT AROMALI %08 100
SUT AROMALI %08 1,00
KEK 35 G KEKSTRA %08 *070
KEK 35 G KEKSTRA %08 0,70
ALISVERIS POSETI %18 0,25
3X1,00
POPKEK MUZLU 6OG %08 3,00
DANKEK 40 GR %08 1,00
DANKEK 40 GR %08 x1.00
2X1,75
ETi KARAM GURME 50 G %08 *3.50
TOPKDV 1,96
TOPLAM 26,15
KREDi KARTI 26,15
Banka Kredi Karti.
Provizyon No527212
iyi sünler, yine bekleriz KASIYERI***A*** EKO NO:0001
ZNO0802 MYAB15024061`

const ocrCanBolat = `CANBOLATMARKET
NURDAG1.VD.1990376834 NO.45NURDAG1/G.ANTEP 03426712946
TESEKKORLER
SAAT1601 TAR1H14/02/2016
F15NO8881
TGIDA %8 *480.00
KDU *35,56
TOP *480.00
NAKIT 00080*
KASIYER:SATIS
ZNO0541 EKUNO:0002
RG11114742`

func TestRealBimKirliTotalSurvivesShiftedColumns(t *testing.T) {
	r := Parse(ocrBimKirli, testCats, now)
	// Etiket/tutar sütunları kaymış: TOPLAM satırında 16,98 görünüyor; doğru toplam
	// nakit - para üstü = 225,00 - 1,35 = 223,65.
	if r.Amount == nil || *r.Amount != 223.65 {
		t.Fatalf("amount = %v, want 223.65", r.Amount)
	}
	if r.Date == nil || *r.Date != "2021-09-04" {
		t.Fatalf("date = %v", r.Date)
	}
	if r.CategoryName != "Market" {
		t.Fatalf("category = %s", r.CategoryName)
	}
	if strings.Contains(r.Merchant, "05445") {
		t.Fatalf("merchant keeps phone junk: %q", r.Merchant)
	}
	for _, it := range r.Items {
		if strings.Contains(it.Name, "%") || strings.HasSuffix(it.Name, "*") {
			t.Fatalf("item name not cleaned: %q", it.Name)
		}
		if strings.Contains(strings.ToLower(it.Name), "adt") {
			t.Fatalf("quantity line counted as item: %q", it.Name)
		}
	}
}

func TestRealBimKoltukDateGluedToLabelAndQuantityLines(t *testing.T) {
	r := Parse(ocrBimKoltuk, testCats, now)
	if r.Date == nil || *r.Date != "2019-12-12" {
		t.Fatalf("date = %v (etiketle yapışık TARIH12.12.2019)", r.Date)
	}
	if r.Amount == nil || *r.Amount != 26.15 {
		t.Fatalf("amount = %v", r.Amount)
	}
	if r.Merchant != "BIM BIRLESIK MAGAZALAR A.S" {
		t.Fatalf("merchant = %q", r.Merchant)
	}
	// 3X1,00 / 2X1,75 adet satırları kalem sayılmamalı; kalemler temiz adlı olmalı.
	for _, it := range r.Items {
		n := strings.ToUpper(it.Name)
		if strings.HasPrefix(n, "3X") || strings.HasPrefix(n, "2X") || strings.Contains(n, "%") {
			t.Fatalf("bad item %+v", it)
		}
	}
	// Meşru bitişik tekrarlar (PAT.CIPSI PATITO x2) silinmemeli.
	patito := 0
	for _, it := range r.Items {
		if strings.HasPrefix(it.Name, "PAT.CIPSI PATITO") {
			patito++
		}
	}
	if patito != 2 {
		t.Fatalf("PAT.CIPSI PATITO count = %d, want 2 (items=%v)", patito, r.Items)
	}
	// OCR iki tutarın ondalık ayıracını düşürdü ("*070", "100"); toplamla doğrulanarak geri kazanılır.
	if len(r.Items) != 17 || r.NeedsReview {
		t.Fatalf("items = %d (want 17), review = %v, itemsTotal = %v", len(r.Items), r.NeedsReview, r.ItemsTotal)
	}
}

func TestRealCanBolatTopLabelAndKduAndGluedDate(t *testing.T) {
	r := Parse(ocrCanBolat, testCats, now)
	if r.Amount == nil || *r.Amount != 480 {
		t.Fatalf("amount = %v", r.Amount)
	}
	if r.Date == nil || *r.Date != "2016-02-14" {
		t.Fatalf("date = %v (TAR1H14/02/2016)", r.Date)
	}
	if r.Merchant != "CANBOLATMARKET" {
		t.Fatalf("merchant = %q", r.Merchant)
	}
	// Tek kalem (TGIDA 480,00) toplamla tuttuğu için uyarı üretmemeli; KDU satırı kalem olmamalı.
	for _, it := range r.Items {
		if strings.Contains(strings.ToUpper(it.Name), "KDU") {
			t.Fatalf("KDU line counted as item: %+v", it)
		}
	}
	if r.NeedsReview {
		t.Fatalf("single item equal to total must not need review: %+v items=%v", r.ItemsTotal, r.Items)
	}
}

func TestKdvLookalikes(t *testing.T) {
	for _, l := range []string{"KDV *35,56", "KDU *35,56", "KDY *35,56", "KOV *35,56", "TOPKDV 1,96"} {
		if !isKDVLine(l) {
			t.Errorf("isKDVLine(%q) = false", l)
		}
	}
	for _, l := range []string{"KEK 35 G KEKSTRA 0,70", "KUR 1,00", "SUT 1L"} {
		if isKDVLine(l) {
			t.Errorf("isKDVLine(%q) = true", l)
		}
	}
}

func TestCleanItemName(t *testing.T) {
	cases := map[string]string{
		"MANTI 450 G MUTFAGIM      %08 *": "MANTI 450 G MUTFAGIM",
		"MANTI 450GMUTFAGIM %08":          "MANTI 450GMUTFAGIM",
		"MAKARNA SPAGETI500G 808":         "MAKARNA SPAGETI500G",
		"MEYVE NEKT.VISNE ILT 80%":        "MEYVE NEKT.VISNE ILT",
		"TIRAS BICAG!6LI %18":             "TIRAS BICAG!6LI",
		"TGIDA %8 *":                      "TGIDA",
		"SUT 1L TAM YAGLI":                "SUT 1L TAM YAGLI",
	}
	for in, want := range cases {
		if got := cleanItemName(in); got != want {
			t.Errorf("cleanItemName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestResolveTotalDoesNotTriggerOnItemPrices(t *testing.T) {
	// 5,00 + 32,50 = 37,50 tesadüfi ilişkisi toplamı bozmamalı.
	r := Parse("MIGROS\n12.05.2026\nEKMEK *5,00\nSUT *32,50\nTOPLAM *37,50\nKREDI KARTI 37,50", testCats, now)
	if r.Amount == nil || *r.Amount != 37.5 {
		t.Fatalf("amount = %v", r.Amount)
	}
}
