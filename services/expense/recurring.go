package main

import (
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"

	"fissio/expense/internal/receiptparse"
)

// Tekrarlayan giderler ("Her ay tekrarlanir"): isaret fisin kendisinde (recurring_day, recurring_remind,
// recurring_kind, recurring_estimate) tutulur.
//
// Cift sayim onlemi: ayni gider her ay yeni bir fis olarak girilir (Ocak ve Subat elektrik faturasi). Projeksiyon
// fis basina degil SERI basina hesaplanir. Seri anahtari = kategori + normalize edilmis isletme adi; serinin
// guncel hali o anahtardaki EN SON fistir (tarih, sonra id). En son fis "tekrarlanir" isaretliyse seri aktiftir
// ve odeme gunu/turu o fisten gelir; en son fis isaretsizse seri bitmis sayilir (kullanici isareti kaldirdi).
//
// Sabit / degisken: kira, abonelik gibi SABIT giderde beklenen tutar son fisin tutaridir. Elektrik, su, dogalgaz
// gibi DEGISKEN faturada tutar her ay degisir; beklenen tutar serinin son 3 AYLIK fis tutarlarinin hareketli
// ortalamasidir (min-max araligiyla). Gecmiste 2'den az ay varsa kullanicinin girdigi tahmini tutar, o da yoksa son
// fis tutari kullanilir. Ayda birden fazla fis varsa o ayin en son fisi sayilir (cift tarama tutari ikiye katlamaz).
//
// Odendi / gerceklesti: serinin icinde bulunulan ayda bir fisi varsa o ayin kalemi "odendi"dir ve projeksiyona
// TAHMIN degil gercek tutar girer; yoksa projeksiyona beklenen tutar girer. Mobildeki ayni hesap: lib/recurring.dart
// (ortak test vektorleri: recurring_test.go <-> test/recurring_logic_test.dart).

const (
	recurringFixed    = "fixed"
	recurringVariable = "variable"
	// recurringWindow hareketli ortalamanin ay sayisi.
	recurringWindow = 3
)

type recurringRow struct {
	ID           int64
	ProfileID    int64
	Merchant     string
	CategoryID   int
	CategoryName string
	Amount       float64
	Date         time.Time
	Day          int // 0 = tekrarlamaz
	Remind       bool
	Kind         string  // fixed | variable
	Estimate     float64 // 0 = tahmin yok
}

type recurringOut struct {
	SeriesKey     string  `json:"series_key"`
	ProfileID     int64   `json:"profile_id"`
	Merchant      string  `json:"merchant"`
	CategoryID    int     `json:"category_id"`
	CategoryName  string  `json:"category_name"`
	Amount        float64 `json:"amount"` // son fisin tutari
	Day           int     `json:"day"`
	Remind        bool    `json:"remind"`
	LastExpenseID int64   `json:"last_expense_id"`
	LastDate      string  `json:"last_date"`
	NextDue       string  `json:"next_due"`
	// Overdue: bu ay odenmedi ve odeme gunu gecti (NextDue gecmis bir tarihtir).
	Overdue bool `json:"overdue"`
	Kind          string  `json:"kind"`
	Estimate      float64 `json:"estimate"`
	// ExpectedAmount bir sonraki (ya da bu ayki odenmemis) fatura icin beklenen tutar; MinAmount/MaxAmount
	// tahmini aralik (sabit giderde ikisi de beklenen tutara esit).
	ExpectedAmount float64 `json:"expected_amount"`
	MinAmount      float64 `json:"min_amount"`
	MaxAmount      float64 `json:"max_amount"`
	// HistoryCount hareketli ortalamaya giren ay sayisi.
	HistoryCount int `json:"history_count"`
	// PaidThisMonth bu ay serinin fisi girilmis (odendi / gerceklesti); ActualAmount o fisin tutari.
	PaidThisMonth bool    `json:"paid_this_month"`
	ActualAmount  float64 `json:"actual_amount"`
	// MonthAmount bu ayin projeksiyonuna giren tutar: odendiyse gercek, degilse beklenen.
	MonthAmount float64 `json:"month_amount"`
}

type recurringTotals struct {
	Monthly   float64 `json:"monthly_total"`
	Paid      float64 `json:"paid_total"`
	Remaining float64 `json:"remaining_total"`
	Min       float64 `json:"min_total"`
	Max       float64 `json:"max_total"`
}

// seriesKey: "<kategori>|<kucuk harf, Turkce katlanmis, harf/rakam jetonlari>"; isletme adi bossa yalnizca kategori.
func seriesKey(merchant string, categoryID int) string {
	toks := strings.FieldsFunc(receiptparse.FoldTR(merchant), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	return strconv.Itoa(categoryID) + "|" + strings.Join(toks, " ")
}

func daysInMonth(y int, m time.Month) int {
	return time.Date(y, m+1, 0, 0, 0, 0, 0, time.UTC).Day()
}

// clampedDate ayin gun sayisini asan gunu (31 Subat gibi) ayin son gunune ceker.
func clampedDate(y int, m time.Month, day int) time.Time {
	// time.Date ay tasmasini normalize eder; once ay tabanini sabitle.
	base := time.Date(y, m, 1, 0, 0, 0, 0, time.UTC)
	y, m = base.Year(), base.Month()
	if n := daysInMonth(y, m); day > n {
		day = n
	}
	return time.Date(y, m, day, 0, 0, 0, 0, time.UTC)
}

// nextDue serinin bir sonraki odeme tarihi: bu ay icin fis girilmediyse bu ayin odeme gunu (GECMIS olsa bile:
// odenmemis fatura "gecikmis" olarak listede ve hatirlatmada kalir), aksi halde gelecek ayin odeme gunu.
// overdue: bu ay odenmedi ve odeme gunu gecti.
func nextDue(day int, last, today time.Time) (due time.Time, overdue bool) {
	y, m := today.Year(), today.Month()
	due = clampedDate(y, m, day)
	paidThisMonth := last.Year() == y && last.Month() == m
	if paidThisMonth {
		return clampedDate(y, m+1, day), false
	}
	return due, due.Before(today)
}

func newerRow(a, b recurringRow) bool { // a, b'den daha yeni mi (tarih, sonra id)
	return a.Date.After(b.Date) || (a.Date.Equal(b.Date) && a.ID > b.ID)
}

// recurringStaleMonths: son fisten bu kadar takvim ayi sonra seri bitmis sayilir.
const recurringStaleMonths = 3

// windowMonths degisken fatura ortalamasina giren AYLARI secer: "son 3 TAKVIM ayi" (fisli son 3 ay degil). Bu ayin
// faturasi girildiyse pencere bu ayla biter, girilmediyse gecen ayla (bu ay henuz bilinmiyor). months en yeni once.
func windowMonths(months []recurringRow, curKey int, paid bool) []recurringRow {
	hi := curKey
	if !paid {
		hi = curKey - 1
	}
	out := []recurringRow{}
	for _, r := range months {
		if k := r.Date.Year()*12 + int(r.Date.Month()); k <= hi && k > hi-recurringWindow {
			out = append(out, r)
		}
	}
	return out
}

// expectation serinin ay bazli (ayda en son fis) gecmisinden beklenen tutari ve araligi cikarir. months en yeni
// once sirali olmali.
func expectation(latest recurringRow, months []recurringRow) (expected, min, max float64, used int) {
	if latest.Kind == recurringVariable {
		w := months
		if len(w) > recurringWindow {
			w = w[:recurringWindow]
		}
		if len(w) >= 2 {
			sum := 0.0
			min, max = w[0].Amount, w[0].Amount
			for _, r := range w {
				sum += r.Amount
				min, max = math.Min(min, r.Amount), math.Max(max, r.Amount)
			}
			return round2(sum / float64(len(w))), round2(min), round2(max), len(w)
		}
		if latest.Estimate > 0 {
			return round2(latest.Estimate), round2(latest.Estimate), round2(latest.Estimate), len(w)
		}
	}
	a := round2(latest.Amount)
	return a, a, a, len(months)
}

// buildRecurring satirlardan aktif serileri cikarir (profil basina ayri seri) ve bu ayin projeksiyonunu hesaplar.
// today UTC gece yarisina indirilmis olmali.
func buildRecurring(rows []recurringRow, today time.Time) ([]recurringOut, recurringTotals) {
	groups := map[string][]recurringRow{}
	for _, r := range rows {
		if r.Date.Year()*12+int(r.Date.Month()) > today.Year()*12+int(today.Month()) {
			continue // GELECEK AYA tarihli fis (onceden girilmis) bu ayin gerceklesmesi/gecmisi sayilmaz (ayni ay icindeki ileri tarih sayilir)
		}
		k := strconv.FormatInt(r.ProfileID, 10) + "#" + seriesKey(r.Merchant, r.CategoryID)
		groups[k] = append(groups[k], r)
	}
	out := []recurringOut{}
	var t recurringTotals
	for _, g := range groups {
		latest := g[0]
		for _, r := range g[1:] {
			if newerRow(r, latest) {
				latest = r
			}
		}
		if latest.Day == 0 {
			continue
		}
		if curMonth := today.Year()*12 + int(today.Month()); curMonth-(latest.Date.Year()*12+int(latest.Date.Month())) > recurringStaleMonths {
			continue // son fisten bu yana > 3 ay gecti: seri bitmis sayilir (sonsuza dek 'gecikmis' kalmasin)
		}
		// Ay bazli gecmis: her ayin en son fisi, en yeni ay once.
		byMonth := map[int]recurringRow{}
		for _, r := range g {
			mk := r.Date.Year()*12 + int(r.Date.Month())
			if cur, ok := byMonth[mk]; !ok || newerRow(r, cur) {
				byMonth[mk] = r
			}
		}
		months := make([]recurringRow, 0, len(byMonth))
		for _, r := range byMonth {
			months = append(months, r)
		}
		sort.Slice(months, func(i, j int) bool { return newerRow(months[i], months[j]) })

		curKey := today.Year()*12 + int(today.Month())
		thisMonth, paid := byMonth[curKey]
		expected, min, max, used := expectation(latest, windowMonths(months, curKey, paid))
		due, overdue := nextDue(latest.Day, latest.Date, today)
		o := recurringOut{
			SeriesKey: seriesKey(latest.Merchant, latest.CategoryID), ProfileID: latest.ProfileID, Merchant: latest.Merchant,
			CategoryID: latest.CategoryID, CategoryName: latest.CategoryName, Amount: round2(latest.Amount), Day: latest.Day,
			Remind: latest.Remind, LastExpenseID: latest.ID, LastDate: latest.Date.Format(dateLayout),
			NextDue: due.Format(dateLayout), Overdue: overdue,
			Kind:    latest.Kind, Estimate: round2(latest.Estimate), ExpectedAmount: expected, MinAmount: min, MaxAmount: max,
			HistoryCount: used, PaidThisMonth: paid,
		}
		if paid {
			// Bu ayin faturasi girildi: tahmin gercek tutarla degisir.
			o.ActualAmount = round2(thisMonth.Amount)
			o.MonthAmount = o.ActualAmount
			t.Paid += o.ActualAmount
			t.Min += o.ActualAmount
			t.Max += o.ActualAmount
		} else {
			o.MonthAmount = expected
			t.Remaining += expected
			t.Min += min
			t.Max += max
		}
		t.Monthly += o.MonthAmount
		out = append(out, o)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].NextDue != out[j].NextDue {
			return out[i].NextDue < out[j].NextDue
		}
		if out[i].ProfileID != out[j].ProfileID {
			return out[i].ProfileID < out[j].ProfileID
		}
		return out[i].SeriesKey < out[j].SeriesKey
	})
	t.Monthly, t.Paid, t.Remaining, t.Min, t.Max = round2(t.Monthly), round2(t.Paid), round2(t.Remaining), round2(t.Min), round2(t.Max)
	return out, t
}

// listRecurring: aktif tekrarlayan giderler ve "Aylik Sabit Gider Projeksiyonu". profile_id verilirse yalnizca o
// profil (sahiplik dogrulanir), verilmezse hesabin tum profilleri.
func (h *handler) listRecurring(c *gin.Context) {
	userID := c.GetInt64("userID")
	q := `SELECT e.id, e.profile_id, e.merchant, e.category_id, c.name, e.amount, e.spent_at, COALESCE(e.recurring_day, 0),
		       e.recurring_remind, e.recurring_kind, COALESCE(e.recurring_estimate, 0)
		FROM expense.expenses e JOIN expense.categories c ON c.id = e.category_id
		WHERE e.user_id = $1
		  AND EXISTS (SELECT 1 FROM expense.expenses r WHERE r.user_id = e.user_id AND r.profile_id = e.profile_id
		              AND r.category_id = e.category_id AND r.recurring_day IS NOT NULL)`
	args := []any{userID}
	if v := c.Query("profile_id"); v != "" {
		pid, ok := h.profileFilter(c, v)
		if !ok {
			return
		}
		args = append(args, pid)
		q += ` AND e.profile_id = $2`
	}
	rows, err := h.db.Query(q, args...)
	if err != nil {
		serverError(c)
		return
	}
	defer rows.Close()
	var all []recurringRow
	for rows.Next() {
		var r recurringRow
		if err := rows.Scan(&r.ID, &r.ProfileID, &r.Merchant, &r.CategoryID, &r.CategoryName, &r.Amount, &r.Date, &r.Day,
			&r.Remind, &r.Kind, &r.Estimate); err != nil {
			serverError(c)
			return
		}
		all = append(all, r)
	}
	if rows.Err() != nil {
		serverError(c)
		return
	}
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	items, t := buildRecurring(all, today)
	c.JSON(http.StatusOK, gin.H{
		"monthly_total": t.Monthly, "paid_total": t.Paid, "remaining_total": t.Remaining,
		"min_total": t.Min, "max_total": t.Max, "count": len(items), "items": items,
	})
}
