package digital

import (
	"strings"
	"time"
	"unicode"
)

// Doc birleştirme kararında kullanılan, depodan bağımsız fiş özeti. Dart ikizi: merge_decision.dart;
// ortak vektörler: testdata/merge_decision.json.
type Doc struct {
	ID          int64
	Merchant    string
	AmountCents int64
	Date        string // YYYY-MM-DD ("" = bilinmiyor)
	DocumentNo  string // ETTN ya da VKN_FaturaNo ("" = yok)
	OrderID     string
	Items       []string
}

// Official: kayıt resmi bir E-Arşiv/E-Fatura belgesine dayanıyor mu (`has_official_invoice` türetimi).
func (d Doc) Official() bool { return d.DocumentNo != "" }

const (
	ActionCreate    = "create"
	ActionDuplicate = "duplicate"
	ActionMerge     = "merge"

	// MergeWindowDays resmi fatura ile ön özet arasındaki en çok gün farkı.
	MergeWindowDays = 3
	// ItemSimilarityMin iki tarafta da kalem varken katlanmış kalem adı jetonlarının en az Jaccard benzerliği.
	ItemSimilarityMin = 0.5
)

type Decision struct {
	Action   string
	TargetID int64
}

// DecideMerge gelen belge için kayıt/mükerrer/birleştirme kararını verir.
//
//	A) Mutlak mükerrer: aynı document_no; ya da aynı order_id + aynı belge türü; ya da ön özet, aynı order_id'li
//	   resmi kayıt varken gelirse (resmi belge zaten kapsıyor).
//	B) Gelen RESMİ belge, resmi bağlanmamış (ön özet) tek bir adaya birleşir: önce order_id eşleşmesi; order_id
//	   yoksa aynı işletme + aynı tutar (kuruş) + ±3 gün + kalem benzerliği ve eşleşen aday TAM 1 ise.
//	C) Asla birleştirme: order_id'ler ikisinde de var ve farklı; gelen ön özet; birden fazla aday (belirsizlik).
func DecideMerge(in Doc, candidates []Doc) Decision {
	// --- A ---
	if in.DocumentNo != "" {
		for _, c := range candidates {
			if c.DocumentNo == in.DocumentNo {
				return Decision{ActionDuplicate, c.ID}
			}
		}
	}
	if in.OrderID != "" {
		for _, c := range candidates {
			if c.OrderID != in.OrderID {
				continue
			}
			if c.Official() == in.Official() || (!in.Official() && c.Official()) {
				return Decision{ActionDuplicate, c.ID}
			}
		}
	}
	// --- C: ön özet asla birleşmez ---
	if !in.Official() {
		return Decision{Action: ActionCreate}
	}
	// --- B ---
	var pool []Doc
	for _, c := range candidates {
		if !c.Official() {
			pool = append(pool, c)
		}
	}
	if in.OrderID != "" {
		var byOrder []Doc
		for _, c := range pool {
			if c.OrderID == in.OrderID {
				byOrder = append(byOrder, c)
			}
		}
		if len(byOrder) == 1 {
			return Decision{ActionMerge, byOrder[0].ID}
		}
		if len(byOrder) > 1 {
			return Decision{Action: ActionCreate}
		}
	}
	var matches []Doc
	for _, c := range pool {
		if in.OrderID != "" && c.OrderID != "" && in.OrderID != c.OrderID {
			continue // C: farklı sipariş
		}
		if fuzzyMatch(in, c) {
			matches = append(matches, c)
		}
	}
	if len(matches) == 1 {
		return Decision{ActionMerge, matches[0].ID}
	}
	return Decision{Action: ActionCreate}
}

func fuzzyMatch(a, b Doc) bool {
	if a.AmountCents != b.AmountCents || a.AmountCents <= 0 {
		return false
	}
	if !withinDays(a.Date, b.Date, MergeWindowDays) {
		return false
	}
	if !merchantMatch(a.Merchant, b.Merchant) {
		return false
	}
	ta, tb := itemTokens(a.Items), itemTokens(b.Items)
	if len(ta) > 0 && len(tb) > 0 && jaccard(ta, tb) < ItemSimilarityMin {
		return false
	}
	return true
}

func withinDays(a, b string, n int) bool {
	ta, err1 := time.Parse("2006-01-02", a)
	tb, err2 := time.Parse("2006-01-02", b)
	if err1 != nil || err2 != nil {
		return false
	}
	d := int(ta.Sub(tb).Hours() / 24)
	if d < 0 {
		d = -d
	}
	return d <= n
}

// keyTokens katlanmış, harf/rakam dışı ayraçlı, ≥2 karakterli jetonlar (Dart ikizi ile aynı).
func keyTokens(s string) []string {
	f := fold(s)
	parts := strings.FieldsFunc(f, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	var out []string
	for _, p := range parts {
		if len([]rune(p)) >= 2 {
			out = append(out, p)
		}
	}
	return out
}

func tokenSet(ts []string) map[string]bool {
	m := map[string]bool{}
	for _, t := range ts {
		m[t] = true
	}
	return m
}

func itemTokens(items []string) map[string]bool {
	m := map[string]bool{}
	for _, it := range items {
		for _, t := range keyTokens(it) {
			m[t] = true
		}
	}
	return m
}

func jaccard(a, b map[string]bool) float64 {
	inter := 0
	for k := range a {
		if b[k] {
			inter++
		}
	}
	union := len(a) + len(b) - inter
	if union == 0 {
		return 0
	}
	return float64(inter) / float64(union)
}

// merchantMatch: jeton kümeleri eşit ya da küçük küme büyüğün alt kümesi ve en az bir ≥3 karakterli ortak jeton.
func merchantMatch(a, b string) bool {
	sa, sb := tokenSet(keyTokens(a)), tokenSet(keyTokens(b))
	if len(sa) == 0 || len(sb) == 0 {
		return false
	}
	small, big := sa, sb
	if len(sa) > len(sb) {
		small, big = sb, sa
	}
	long := false
	for t := range small {
		if !big[t] {
			return false
		}
		if len([]rune(t)) >= 3 {
			long = true
		}
	}
	return long
}
