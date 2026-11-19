package receiptparse

import (
	"strings"
	"testing"
)

func TestMergePageTextsSingleAndEmpty(t *testing.T) {
	if got := MergePageTexts([]string{"A 1,00\nB 2,00"}); got != "A 1,00\nB 2,00" {
		t.Fatalf("single page = %q", got)
	}
	if got := MergePageTexts([]string{"", "  ", "X 1,00"}); got != "X 1,00" {
		t.Fatalf("empty pages = %q", got)
	}
	if got := MergePageTexts(nil); got != "" {
		t.Fatalf("nil = %q", got)
	}
}

func TestMergePageTextsRemovesTwoLineOverlap(t *testing.T) {
	p1 := "BIM A.S\nSUT 1,00\nEKMEK 5,00\nPEYNIR 60,00"
	p2 := "EKMEK 5,00\nPEYNIR 60,00\nYUMURTA 10,90\nTOPLAM 76,90"
	want := "BIM A.S\nSUT 1,00\nEKMEK 5,00\nPEYNIR 60,00\nYUMURTA 10,90\nTOPLAM 76,90"
	if got := MergePageTexts([]string{p1, p2}); got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
}

func TestMergePageTextsOverlapToleratesOCRNoise(t *testing.T) {
	// Aynı satırlar iki fotoğrafta birebir aynı okunmaz; rakamlar aynı kalmalı.
	p1 := "A 1,00\nSUT AROMALI 1,00\nETI KARAM GURME 50 G 1,75"
	p2 := "SUT AR0MALI 1,00\nETIKARAM GURME 50 G 1,75\nKEK 0,70"
	got := MergePageTexts([]string{p1, p2})
	if strings.Count(got, "1,75") != 1 || !strings.HasSuffix(got, "KEK 0,70") {
		t.Fatalf("noisy overlap not removed: %q", got)
	}
}

func TestMergePageTextsKeepsLegitimateRepeatAcrossCleanCut(t *testing.T) {
	// Dikiş iki meşru PAT.CIPSI satırının tam arasına denk geliyor, fotoğraflar çakışmıyor:
	// tek satırlık benzerlik silinmemeli.
	p1 := "BIM\nSUT 1,00\nPAT.CIPSI PATITO 3,25"
	p2 := "PAT.CIPSI PATITO 3,25\nETI KARAM 1,75"
	got := MergePageTexts([]string{p1, p2})
	if strings.Count(got, "PAT.CIPSI PATITO 3,25") != 2 {
		t.Fatalf("legit repeat removed: %q", got)
	}
}

func TestMergePageTextsDifferentAmountsAreNotOverlap(t *testing.T) {
	p1 := "SUT 1,00\nEKMEK 5,00"
	p2 := "SUT 1,50\nEKMEK 6,00\nPEYNIR 9,00"
	got := MergePageTexts([]string{p1, p2})
	if strings.Count(got, "SUT") != 2 || strings.Count(got, "EKMEK") != 2 {
		t.Fatalf("lines with different amounts were merged: %q", got)
	}
}

func TestMergePageTextsOverlapWithCutThroughFirstLine(t *testing.T) {
	// Ikinci fotograf bir satirin ortasindan basliyor: ilk satir yarim parca. Parca + cakisan
	// satirlar birlikte atilmali.
	join := func(l ...string) string { return strings.Join(l, "\n") }
	p1 := join("SUT 1,00", "ETI KARAM 1,75", "200ML.MUZ.SUT 1,00", "SUT AROMALI 1,00")
	p2 := join("%08 *175", "200ML.MUZ.SUT 1,00", "SUT AROMALI 1,00", "KEK 0,70")
	want := join("SUT 1,00", "ETI KARAM 1,75", "200ML.MUZ.SUT 1,00", "SUT AROMALI 1,00", "KEK 0,70")
	if got := MergePageTexts([]string{p1, p2}); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}
