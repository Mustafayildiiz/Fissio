package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// loadTestdata okur <repo>/testdata/<name> (Go, Python ve Dart testleri ayni altin vektorleri kullanir).
func loadTestdata(t *testing.T, name string, v any) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", name))
	if err != nil {
		t.Fatalf("testdata/%s okunamadi: %v", name, err)
	}
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("testdata/%s bozuk: %v", name, err)
	}
}

// testdata/recurring_due.json: Dart recurring.dart nextDueDate ayni vektorleri okur.
func TestNextDueGoldenVectors(t *testing.T) {
	var data struct {
		Cases []struct {
			Day     int    `json:"day"`
			Last    string `json:"last"`
			Today   string `json:"today"`
			NextDue string `json:"next_due"`
			Overdue bool   `json:"overdue"`
		} `json:"cases"`
	}
	loadTestdata(t, "recurring_due.json", &data)
	if len(data.Cases) < 8 {
		t.Fatalf("recurring_due.json beklenenden kisa: %d", len(data.Cases))
	}
	parse := func(s string) time.Time {
		d, err := time.Parse(dateLayout, s)
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	for _, c := range data.Cases {
		due, overdue := nextDue(c.Day, parse(c.Last), parse(c.Today))
		if got := due.Format(dateLayout); got != c.NextDue || overdue != c.Overdue {
			t.Errorf("day=%d last=%s today=%s: %s/%v, beklenen %s/%v", c.Day, c.Last, c.Today, got, overdue, c.NextDue, c.Overdue)
		}
	}
}
