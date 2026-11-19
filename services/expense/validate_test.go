package main

import "testing"

func TestCleanText(t *testing.T) {
	cases := map[string]string{
		"BIM MARKET":      "BIM MARKET",
		"ŞEKER İÇECEK":    "ŞEKER İÇECEK",
		"a\x00b":          "ab",
		"a\x01\x02\x1fb":  "ab",
		"tab\there\nline": "tab\there\nline",
		"c1\u0085ctrl":    "c1ctrl",
		"bad\xffutf8":     "badutf8",
	}
	for in, want := range cases {
		if got := cleanText(in); got != want {
			t.Errorf("cleanText(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestValidateStripsControlCharsAndBoundsAmount(t *testing.T) {
	in := expenseInput{Merchant: "BIM\x00", Note: "n\x01", Amount: 10, Date: "2026-05-12",
		Items: []expenseItem{{Name: "SUT\x00", Amount: 5}}}
	if _, msg := in.validate(); msg != "" {
		t.Fatalf("validate: %s", msg)
	}
	if in.Merchant != "BIM" || in.Note != "n" || in.Items[0].Name != "SUT" {
		t.Fatalf("control characters must be stripped: %+v", in)
	}

	// 9999999999.999 yuvarlaninca 1e10 olur ve NUMERIC(12,2)'yi tasirir: reddedilmeli.
	over := expenseInput{Amount: 9999999999.999, Date: "2026-05-12"}
	if _, msg := over.validate(); msg == "" {
		t.Fatal("amount that rounds to 1e10 must be rejected")
	}
	max := expenseInput{Amount: 9999999999.99, Date: "2026-05-12"}
	if _, msg := max.validate(); msg != "" {
		t.Fatalf("largest storable amount must be accepted: %s", msg)
	}
}
