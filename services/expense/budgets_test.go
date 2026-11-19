package main

import (
	"testing"
	"time"
)

func TestBudgetStatusBoundaries(t *testing.T) {
	for _, tc := range []struct {
		spent, limit float64
		want         string
	}{
		{0, 8000, "ok"},
		{6399.99, 8000, "ok"},      // %79,99
		{6400, 8000, "warning"},    // tam %80
		{7999.99, 8000, "warning"}, // %99,99
		{8000, 8000, "exceeded"},   // tam %100
		{9500, 8000, "exceeded"},
		{0.1 + 0.2, 0.3, "exceeded"}, // kayan nokta: 0,30000000000000004 >= 0,30
		{5, 0, "ok"},                 // limit yok
	} {
		if got := budgetStatus(tc.spent, tc.limit); got != tc.want {
			t.Errorf("budgetStatus(%v, %v) = %s, want %s", tc.spent, tc.limit, got, tc.want)
		}
	}
}

func day(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 0, 0, 0, 0, time.UTC) }

func TestSeriesKeyFoldsTurkishAndPunctuation(t *testing.T) {
	a := seriesKey("Enerjisa  Elektrik", 7)
	b := seriesKey("ENERJISA elektrik.", 7)
	if a != b {
		t.Fatalf("keys differ: %q %q", a, b)
	}
	if seriesKey("Enerjisa", 7) == seriesKey("Enerjisa", 8) {
		t.Fatal("category must be part of the key")
	}
	if got := seriesKey("", 3); got != "3|" {
		t.Fatalf("empty merchant key = %q", got)
	}
}

func TestRecurringProjectionCountsSeriesOnce(t *testing.T) {
	today := day(2026, time.May, 10)
	rows := []recurringRow{
		// Elektrik: Mart, Nisan, Mayis faturalari -> tek seri, en son tutar (400).
		{ID: 1, ProfileID: 1, Merchant: "Enerjisa", CategoryID: 7, Amount: 300, Date: day(2026, time.March, 25), Day: 25, Remind: true},
		{ID: 2, ProfileID: 1, Merchant: "ENERJISA", CategoryID: 7, Amount: 350, Date: day(2026, time.April, 25), Day: 25, Remind: true},
		{ID: 3, ProfileID: 1, Merchant: "Enerjisa", CategoryID: 7, Amount: 400, Date: day(2026, time.May, 5), Day: 25, Remind: true},
		// Kira: Nisan'da girilmis, bu ay henuz girilmemis.
		{ID: 4, ProfileID: 1, Merchant: "Ev sahibi", CategoryID: 8, Amount: 12000, Date: day(2026, time.April, 1), Day: 1, Remind: false},
	}
	items, totals := buildRecurring(rows, today)
	if total := totals.Monthly; len(items) != 2 || total != 12400 {
		t.Fatalf("items=%d total=%v: %+v", len(items), total, items)
	}
	byMerchant := map[string]recurringOut{}
	for _, it := range items {
		byMerchant[it.Merchant] = it
	}
	el := byMerchant["Enerjisa"]
	if el.Amount != 400 || el.LastExpenseID != 3 {
		t.Fatalf("latest occurrence must win: %+v", el)
	}
	// Mayis faturasi zaten girildi (5 Mayis) -> sonraki odeme Haziran 25.
	if el.NextDue != "2026-06-25" {
		t.Fatalf("electricity next due = %s", el.NextDue)
	}
	// Kira 1'inde, bu ayin 1'i gecti ama bu ay girilmedi -> GECIKMIS: vade 1 Mayis kalir (listeden dusmez).
	if rent := byMerchant["Ev sahibi"]; rent.NextDue != "2026-05-01" || !rent.Overdue {
		t.Fatalf("rent next due = %s overdue=%v", rent.NextDue, rent.Overdue)
	}
	if el.Overdue {
		t.Fatal("odenmis fatura gecikmis sayilmamali")
	}
}

func TestRecurringSeriesEndsWhenLatestIsNotMarkedAndProfilesAreSeparate(t *testing.T) {
	today := day(2026, time.May, 10)
	rows := []recurringRow{
		{ID: 1, ProfileID: 1, Merchant: "Netflix", CategoryID: 9, Amount: 100, Date: day(2026, time.March, 3), Day: 3},
		{ID: 2, ProfileID: 1, Merchant: "Netflix", CategoryID: 9, Amount: 100, Date: day(2026, time.April, 3), Day: 0}, // isaret kaldirildi
		// Ayni isletme baska profilde ayri seri.
		{ID: 3, ProfileID: 2, Merchant: "Netflix", CategoryID: 9, Amount: 120, Date: day(2026, time.April, 3), Day: 3},
	}
	items, totals := buildRecurring(rows, today)
	if total := totals.Monthly; len(items) != 1 || items[0].ProfileID != 2 || total != 120 {
		t.Fatalf("items=%+v total=%v", items, total)
	}
}

func nextDueDay(day int, last, today time.Time) time.Time {
	due, _ := nextDue(day, last, today)
	return due
}

func TestNextDueClampsToMonthLength(t *testing.T) {
	// 31. gun, Subat: ayin son gunu (28 / artik yilda 29).
	if got := nextDueDay(31, day(2026, time.January, 31), day(2026, time.February, 2)).Format(dateLayout); got != "2026-02-28" {
		t.Fatalf("feb 2026: %s", got)
	}
	if got := nextDueDay(31, day(2027, time.December, 31), day(2028, time.February, 2)).Format(dateLayout); got != "2028-02-29" {
		t.Fatalf("feb 2028: %s", got)
	}
	// Ay sonunda: sonraki ay (yil donumu dahil).
	if got := nextDueDay(15, day(2026, time.December, 15), day(2026, time.December, 20)).Format(dateLayout); got != "2027-01-15" {
		t.Fatalf("year rollover: %s", got)
	}
	// Bugun odeme gunu ve bu ay icin fis yok -> bugun.
	if got := nextDueDay(10, day(2026, time.April, 10), day(2026, time.May, 10)).Format(dateLayout); got != "2026-05-10" {
		t.Fatalf("due today: %s", got)
	}
}
