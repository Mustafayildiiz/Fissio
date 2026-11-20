package main

import (
	"testing"
	"time"
)

// testdata/recurring_series.json: Dart recurring.dart buildRecurring ayni vektorleri okur.
func TestRecurringSeriesGoldenVectors(t *testing.T) {
	var data struct {
		Cases []struct {
			Name  string `json:"name"`
			Today string `json:"today"`
			Rows  []struct {
				Merchant string  `json:"merchant"`
				Category int     `json:"category_id"`
				Amount   float64 `json:"amount"`
				Date     string  `json:"date"`
				Day      int     `json:"day"`
				Kind     string  `json:"kind"`
				Estimate float64 `json:"estimate"`
			} `json:"rows"`
			Expect struct {
				Monthly float64 `json:"monthly_total"`
				Series  []struct {
					Merchant string  `json:"merchant"`
					Expected float64 `json:"expected"`
					Min      float64 `json:"min"`
					Max      float64 `json:"max"`
					History  int     `json:"history"`
					Paid     bool    `json:"paid"`
					Overdue  bool    `json:"overdue"`
					NextDue  string  `json:"next_due"`
					Amount   float64 `json:"amount"`
					// Counts: toplama dahil mi; vektorde yoksa true beklenir.
					Counts *bool `json:"counts_in_total"`
				} `json:"series"`
			} `json:"expect"`
		} `json:"cases"`
	}
	loadTestdata(t, "recurring_series.json", &data)
	if len(data.Cases) < 4 {
		t.Fatalf("recurring_series.json beklenenden kisa: %d", len(data.Cases))
	}
	for _, c := range data.Cases {
		today, _ := time.Parse(dateLayout, c.Today)
		var rows []recurringRow
		for i, r := range c.Rows {
			d, _ := time.Parse(dateLayout, r.Date)
			rows = append(rows, recurringRow{ID: int64(i + 1), ProfileID: 1, Merchant: r.Merchant, CategoryID: r.Category, CategoryName: "x",
				Amount: r.Amount, Date: d, Day: r.Day, Remind: true, Kind: r.Kind, Estimate: r.Estimate})
		}
		items, tot := buildRecurring(rows, today)
		if len(items) != len(c.Expect.Series) || tot.Monthly != c.Expect.Monthly {
			t.Errorf("%s: %d seri / toplam %v, beklenen %d / %v", c.Name, len(items), tot.Monthly, len(c.Expect.Series), c.Expect.Monthly)
			continue
		}
		for i, w := range c.Expect.Series {
			g := items[i]
			if g.Merchant != w.Merchant || g.ExpectedAmount != w.Expected || g.MinAmount != w.Min || g.MaxAmount != w.Max ||
				g.HistoryCount != w.History || g.PaidThisMonth != w.Paid || g.Overdue != w.Overdue || g.NextDue != w.NextDue || g.Amount != w.Amount ||
				g.CountsInTotal != (w.Counts == nil || *w.Counts) {
				t.Errorf("%s[%d]: %+v, beklenen %+v", c.Name, i, g, w)
			}
		}
	}
}
