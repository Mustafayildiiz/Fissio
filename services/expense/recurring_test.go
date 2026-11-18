package main

import (
	"testing"
	"time"
)

// Sabit / degisken tutarli tekrarlayan giderlerin projeksiyonu. Ayni vektorler mobilde de var:
// fissio_mobile/test/recurring_logic_test.dart ("ortak vektorler"); ikisi birlikte degismeli.

func vrow(id int64, merchant string, amount float64, date time.Time, day int, kind string, est float64) recurringRow {
	return recurringRow{
		ID: id, ProfileID: 1, Merchant: merchant, CategoryID: 7, CategoryName: "Fatura / Abonelik",
		Amount: amount, Date: date, Day: day, Remind: true, Kind: kind, Estimate: est,
	}
}

func itemOf(t *testing.T, items []recurringOut, merchant string) recurringOut {
	t.Helper()
	for _, it := range items {
		if it.Merchant == merchant {
			return it
		}
	}
	t.Fatalf("series %q missing in %+v", merchant, items)
	return recurringOut{}
}

func electricity() []recurringRow {
	return []recurringRow{
		vrow(1, "CK Elektrik", 400, day(2026, time.February, 20), 20, recurringVariable, 0),
		vrow(2, "CK Elektrik", 500, day(2026, time.March, 20), 20, recurringVariable, 0),
		vrow(3, "CK Elektrik", 600, day(2026, time.April, 20), 20, recurringVariable, 0),
	}
}

func TestVariableBillUsesMovingAverageWithRange(t *testing.T) {
	today := day(2026, time.May, 15)
	items, tot := buildRecurring(electricity(), today)
	el := itemOf(t, items, "CK Elektrik")
	if el.Kind != recurringVariable || el.ExpectedAmount != 500 || el.MinAmount != 400 || el.MaxAmount != 600 || el.HistoryCount != 3 {
		t.Fatalf("moving average: %+v", el)
	}
	if el.PaidThisMonth || el.MonthAmount != 500 || el.NextDue != "2026-05-20" {
		t.Fatalf("unpaid month: %+v", el)
	}
	if tot.Monthly != 500 || tot.Remaining != 500 || tot.Paid != 0 || tot.Min != 400 || tot.Max != 600 {
		t.Fatalf("totals: %+v", tot)
	}
}

func TestVariableBillBecomesPaidWithActualAmountWhenNewMonthIsAdded(t *testing.T) {
	today := day(2026, time.May, 15)
	rows := append(electricity(), vrow(4, "CK Elektrik", 520, day(2026, time.May, 18), 20, recurringVariable, 0))
	// "Bugun" 18 Mayis'tan once olsa da fis bu aya ait: gerceklesti.
	items, tot := buildRecurring(rows, today)
	el := itemOf(t, items, "CK Elektrik")
	if !el.PaidThisMonth || el.ActualAmount != 520 || el.MonthAmount != 520 {
		t.Fatalf("must switch to paid with the real amount: %+v", el)
	}
	// Bir sonraki ay icin beklenen: son 3 ay (Nisan 600, Mart 500, Mayis 520) ortalamasi 540, aralik 500-600.
	if el.ExpectedAmount != 540 || el.MinAmount != 500 || el.MaxAmount != 600 || el.NextDue != "2026-06-20" {
		t.Fatalf("next expectation: %+v", el)
	}
	if tot.Monthly != 520 || tot.Paid != 520 || tot.Remaining != 0 || tot.Min != 520 || tot.Max != 520 {
		t.Fatalf("totals must use the actual amount: %+v", tot)
	}
}

func TestFixedExpenseKeepsLastAmountAndMixedProjection(t *testing.T) {
	today := day(2026, time.May, 15)
	rows := append(electricity(),
		vrow(10, "Ev sahibi", 4500, day(2026, time.March, 1), 1, recurringFixed, 0),
		vrow(11, "Ev sahibi", 5000, day(2026, time.April, 1), 1, recurringFixed, 0),
		vrow(12, "Ev sahibi", 5000, day(2026, time.May, 1), 1, recurringFixed, 0),
	)
	items, tot := buildRecurring(rows, today)
	kira := itemOf(t, items, "Ev sahibi")
	if kira.Kind != recurringFixed || kira.ExpectedAmount != 5000 || kira.MinAmount != 5000 || kira.MaxAmount != 5000 {
		t.Fatalf("fixed must not be averaged: %+v", kira)
	}
	if !kira.PaidThisMonth || kira.MonthAmount != 5000 {
		t.Fatalf("rent is paid this month: %+v", kira)
	}
	// Kira (odendi, gercek 5000) + Elektrik (tahmin 500).
	if len(items) != 2 || tot.Monthly != 5500 || tot.Paid != 5000 || tot.Remaining != 500 || tot.Min != 5400 || tot.Max != 5600 {
		t.Fatalf("mixed totals: %+v %+v", tot, items)
	}
}

func TestVariableFallsBackToEstimateThenLastAmountAndCapsWindow(t *testing.T) {
	today := day(2026, time.May, 15)
	// Tek fis + kullanicinin tahmini.
	items, _ := buildRecurring([]recurringRow{vrow(1, "Su", 250, day(2026, time.April, 10), 10, recurringVariable, 300)}, today)
	su := itemOf(t, items, "Su")
	if su.ExpectedAmount != 300 || su.MinAmount != 300 || su.MaxAmount != 300 || su.HistoryCount != 1 || su.Estimate != 300 {
		t.Fatalf("estimate fallback: %+v", su)
	}
	// Tek fis, tahmin yok: son tutar.
	items, _ = buildRecurring([]recurringRow{vrow(1, "Su", 250, day(2026, time.April, 10), 10, recurringVariable, 0)}, today)
	if su := itemOf(t, items, "Su"); su.ExpectedAmount != 250 {
		t.Fatalf("last-amount fallback: %+v", su)
	}
	// 2 ay gecmis varsa tahmin degil gecmis ortalamasi kullanilir.
	items, _ = buildRecurring([]recurringRow{
		vrow(1, "Su", 200, day(2026, time.March, 10), 10, recurringVariable, 0),
		vrow(2, "Su", 300, day(2026, time.April, 10), 10, recurringVariable, 999),
	}, today)
	if su := itemOf(t, items, "Su"); su.ExpectedAmount != 250 || su.MinAmount != 200 || su.MaxAmount != 300 || su.HistoryCount != 2 {
		t.Fatalf("two-month average: %+v", su)
	}
	// Pencere en fazla 3 ay: Ocak'taki 5000 yok sayilir.
	rows := append(electricity(), vrow(9, "CK Elektrik", 5000, day(2026, time.January, 20), 20, recurringVariable, 0))
	items, _ = buildRecurring(rows, today)
	if el := itemOf(t, items, "CK Elektrik"); el.ExpectedAmount != 500 || el.HistoryCount != 3 {
		t.Fatalf("window must cap at 3 months: %+v", el)
	}
	// Ayni ayda iki fis: ayin en son fisi sayilir (cift tarama tutari ikiye katlamaz).
	rows = []recurringRow{
		vrow(1, "Gaz", 100, day(2026, time.March, 10), 10, recurringVariable, 0),
		vrow(2, "Gaz", 100, day(2026, time.April, 10), 10, recurringVariable, 0),
		vrow(3, "Gaz", 700, day(2026, time.April, 25), 10, recurringVariable, 0),
	}
	items, _ = buildRecurring(rows, today)
	if g := itemOf(t, items, "Gaz"); g.ExpectedAmount != 400 || g.HistoryCount != 2 {
		t.Fatalf("one receipt per month: %+v", g)
	}
}

func TestVariableKindAndEstimateArgs(t *testing.T) {
	in := expenseInput{RecurringDay: 10, RecurringKind: "variable", RecurringEstimate: 300}
	if in.kind() != "variable" || in.estimateArg() != 300.0 {
		t.Fatalf("variable: %v %v", in.kind(), in.estimateArg())
	}
	for _, in := range []expenseInput{
		{RecurringDay: 10, RecurringKind: "fixed", RecurringEstimate: 300}, // sabitte tahmin tutulmaz
		{RecurringDay: 0, RecurringKind: "variable", RecurringEstimate: 300},
		{RecurringDay: 10, RecurringKind: "variable"},
	} {
		if in.estimateArg() != nil {
			t.Fatalf("estimate must be NULL: %+v", in)
		}
	}
	bad := expenseInput{Amount: 1, Date: "2026-05-01", RecurringKind: "weekly"}
	if _, msg := bad.validate(); msg == "" {
		t.Fatal("unknown recurring_kind must be rejected")
	}
}
