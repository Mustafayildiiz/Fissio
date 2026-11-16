package main

import (
	"math"
	"strings"
)

// Cok sayfali (uzun) fislerde sayfa metinlerini tek fis metnine birlestirir.
//
// Sayfalar arasi cakisan satirlar YALNIZCA en az 2 ardisik satir cakisiyorsa silinir: BIM gibi
// fislerde mesru bitisik tekrarlar vardir (PAT.CIPSI x2, MANTI x2) ve dikis bunlarin arasina
// denk gelebilir. Tek satirlik cakisma korunur; gercek cift okumayi reconcileItems toplamla
// dogrulayip temizler.
const (
	seamMaxOverlap = 6 // dikiste aranacak en fazla cakisan satir sayisi
	seamMinOverlap = 2 // bu kadar ardisik satir cakismadikca hicbir sey silinmez
)

func mergePageTexts(pages []string) string {
	var merged []string
	for _, p := range pages {
		lines := splitLines(p)
		if len(lines) == 0 {
			continue
		}
		if len(merged) > 0 {
			lines = lines[seamOverlap(merged, lines):]
		}
		merged = append(merged, lines...)
	}
	return strings.Join(merged, "\n")
}

// seamOverlap, sonraki sayfadan atilacak bas satir sayisini dondurur (0 = cakisma yok).
// Onceki metnin son k satiri ile sonraki metnin k satiri (bulanik) ayniysa k >= seamMinOverlap
// olmak uzere cakisma vardir. Fotograf bir satirin ortasindan kesildiyse sonraki sayfanin ILK
// satiri yarim (parca) kalir; bu yuzden o parca satir atlanarak da eslesme aranir ve parca satir
// ile birlikte atilir.
func seamOverlap(prev, next []string) int {
	bestDrop, bestK := 0, 0
	for skip := 0; skip <= 1; skip++ {
		maxK := seamMaxOverlap
		if len(prev) < maxK {
			maxK = len(prev)
		}
		if len(next)-skip < maxK {
			maxK = len(next) - skip
		}
		for k := maxK; k >= seamMinOverlap && k > bestK; k-- {
			ok := true
			for i := 0; i < k; i++ {
				if !fuzzyLineEqual(prev[len(prev)-k+i], next[skip+i]) {
					ok = false
					break
				}
			}
			if ok {
				bestDrop, bestK = skip+k, k
				break
			}
		}
	}
	return bestDrop
}

// fuzzyLineEqual, ayni satirin iki farkli fotografta okunmus halini eslestirir: harf farklari
// (AR0MALI/AROMALI gibi rakam-harf karisikliklari dahil) birkac duzenlemeye kadar tolere edilir,
// ancak satirdaki TUTARLAR birebir ayni olmalidir.
func fuzzyLineEqual(a, b string) bool {
	fa := strings.ReplaceAll(foldTR(a), " ", "")
	fb := strings.ReplaceAll(foldTR(b), " ", "")
	if fa == "" || fb == "" {
		return false
	}
	if !sameAmounts(amountsIn(a), amountsIn(b)) {
		return false
	}
	limit := len([]rune(fa)) / 6
	if limit < 1 {
		limit = 1
	}
	return levenshtein(fa, fb) <= limit
}

func sameAmounts(a, b []float64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if math.Abs(a[i]-b[i]) > 0.005 {
			return false
		}
	}
	return true
}
