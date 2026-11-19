package scan

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeOcr, OcrEngine'in test uygulamasidir: sayfa icerigi (ilk bayt) ile davranisi secilir.
type fakeOcr struct {
	fn    func(ctx context.Context, img []byte, attempt int) (*OcrExtractionResult, error)
	mu    sync.Mutex
	calls map[byte]int
	cur   atomic.Int32
	peak  atomic.Int32
}

func (f *fakeOcr) Name() string { return "fake" }
func (f *fakeOcr) ExtractText(ctx context.Context, img []byte) (*OcrExtractionResult, error) {
	n := f.cur.Add(1)
	defer f.cur.Add(-1)
	for {
		p := f.peak.Load()
		if n <= p || f.peak.CompareAndSwap(p, n) {
			break
		}
	}
	f.mu.Lock()
	if f.calls == nil {
		f.calls = map[byte]int{}
	}
	f.calls[img[0]]++
	attempt := f.calls[img[0]]
	f.mu.Unlock()
	return f.fn(ctx, img, attempt)
}

func (f *fakeOcr) callsFor(b byte) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[b]
}

func okPage(text string) *OcrExtractionResult {
	return &OcrExtractionResult{RawText: text, Confidence: 0.9, Engine: "fake", ModelVersion: "v1", Blocks: []OcrTextBlock{{Text: text}}, Metadata: map[string]any{"rec_model": "m"}}
}

func fastScanSettings(t *testing.T) {
	t.Helper()
	pt, tt, par, pause, budget := scanPageTimeout, scanTotalTimeout, scanParallelism, scanRetryPause, scanMinRetryBudget
	scanRetryPause, scanMinRetryBudget = time.Millisecond, 0
	t.Cleanup(func() {
		scanPageTimeout, scanTotalTimeout, scanParallelism, scanRetryPause, scanMinRetryBudget = pt, tt, par, pause, budget
	})
}

func TestRunScanKeepsPageOrderAndBoundsParallelism(t *testing.T) {
	fastScanSettings(t)
	scanParallelism = 2
	eng := &fakeOcr{fn: func(ctx context.Context, img []byte, _ int) (*OcrExtractionResult, error) {
		page := img[0]
		time.Sleep(time.Duration(10-int(page)) * 3 * time.Millisecond) // sonraki sayfalar once biter
		return okPage(string(rune('A' + page))), nil
	}}
	pages := [][]byte{{0}, {1}, {2}, {3}, {4}, {5}}
	res := Run(context.Background(), eng, pages)
	agg, failed, _ := Assemble(res)
	if len(failed) != 0 {
		t.Fatalf("failed = %v", failed)
	}
	if agg.RawText != "A\nB\nC\nD\nE\nF" {
		t.Fatalf("sayfa sirasi bozuldu: %q", agg.RawText)
	}
	if p := eng.peak.Load(); p != 2 {
		t.Fatalf("paralellik zirvesi = %d, want 2", p)
	}
	if agg.Metadata["rec_model"] != "m" || agg.PageCount != 6 || agg.Engine != "fake" {
		t.Fatalf("agg = %+v", agg)
	}
	for i, p := range pages { // gorsel bellekten silinir
		if p[0] != 0 {
			t.Fatalf("sayfa %d temizlenmedi", i)
		}
	}
}

func TestRunScanRetriesTransientFailureOnce(t *testing.T) {
	fastScanSettings(t)
	eng := &fakeOcr{fn: func(ctx context.Context, img []byte, attempt int) (*OcrExtractionResult, error) {
		if attempt == 1 {
			return nil, ErrOcrUnavailable
		}
		return okPage("tamam"), nil
	}}
	res := Run(context.Background(), eng, [][]byte{{7}})
	if res[0].Err != nil || eng.callsFor(7) != 2 {
		t.Fatalf("err=%v calls=%d", res[0].Err, eng.callsFor(7))
	}
	// Gecersiz gorsel tekrar denenmez.
	eng2 := &fakeOcr{fn: func(context.Context, []byte, int) (*OcrExtractionResult, error) { return nil, ErrInvalidOcrInput }}
	res = Run(context.Background(), eng2, [][]byte{{8}})
	if !errors.Is(res[0].Err, ErrInvalidOcrInput) || eng2.callsFor(8) != 1 {
		t.Fatalf("err=%v calls=%d", res[0].Err, eng2.callsFor(8))
	}
	_, failed, allInvalid := Assemble(res)
	if len(failed) != 1 || !allInvalid {
		t.Fatalf("failed=%v allInvalid=%v", failed, allInvalid)
	}
}

func TestRunScanPartialResultReportsFailedPages(t *testing.T) {
	fastScanSettings(t)
	eng := &fakeOcr{fn: func(ctx context.Context, img []byte, _ int) (*OcrExtractionResult, error) {
		if img[0] == 1 {
			return nil, errors.New("dial tcp 10.0.0.5:8080: connection refused")
		}
		return okPage(string(rune('A' + img[0]))), nil
	}}
	agg, failed, allInvalid := Assemble(Run(context.Background(), eng, [][]byte{{0}, {1}, {2}}))
	if len(failed) != 1 || failed[0] != 2 || allInvalid {
		t.Fatalf("failed=%v allInvalid=%v", failed, allInvalid)
	}
	if len(agg.PageTexts) != 3 || agg.PageTexts[0] != "A" || agg.PageTexts[1] != "" || agg.PageTexts[2] != "C" {
		t.Fatalf("PageTexts sayfa sirasina hizali olmali: %q", agg.PageTexts)
	}
	if agg.RawText != "A\nC" || agg.Confidence != 0.9 {
		t.Fatalf("agg = %+v", agg)
	}
}

func TestRunScanPageTimeoutAndTotalDeadline(t *testing.T) {
	fastScanSettings(t)
	scanPageTimeout = 20 * time.Millisecond
	slow := &fakeOcr{fn: func(ctx context.Context, _ []byte, _ int) (*OcrExtractionResult, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	start := time.Now()
	res := Run(context.Background(), slow, [][]byte{{1}})
	if res[0].Err == nil || time.Since(start) > time.Second || slow.callsFor(1) != 2 {
		t.Fatalf("err=%v elapsed=%v calls=%d", res[0].Err, time.Since(start), slow.callsFor(1))
	}

	// Toplam deadline: kalan sayfalar baslamadan iptal olur.
	scanPageTimeout, scanTotalTimeout, scanParallelism = time.Second, 50*time.Millisecond, 1
	slow2 := &fakeOcr{fn: func(ctx context.Context, _ []byte, _ int) (*OcrExtractionResult, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	start = time.Now()
	res = Run(context.Background(), slow2, [][]byte{{1}, {2}, {3}, {4}})
	if time.Since(start) > 2*time.Second {
		t.Fatalf("deadline isletilmedi: %v", time.Since(start))
	}
	_, failed, _ := Assemble(res)
	if len(failed) != 4 {
		t.Fatalf("failed = %v", failed)
	}
}

func TestScanLimiter(t *testing.T) {
	l := NewLimiter(2, 3)
	now := time.Now()
	r1, ok, _ := l.Acquire(1, now)
	r2, ok2, _ := l.Acquire(1, now)
	if !ok || !ok2 {
		t.Fatal("ilk iki tarama kabul edilmeli")
	}
	if _, ok, reason := l.Acquire(1, now); ok || reason != "busy" {
		t.Fatalf("ucuncu es zamanli tarama reddedilmeli: %v %q", ok, reason)
	}
	if _, ok, _ := l.Acquire(2, now); !ok {
		t.Fatal("baska kullanici etkilenmemeli")
	}
	r1()
	r3, ok, _ := l.Acquire(1, now)
	if !ok {
		t.Fatal("yer acilinca kabul edilmeli")
	}
	r2()
	r3()
	if _, ok, reason := l.Acquire(1, now); ok || reason != "rate" {
		t.Fatalf("dakikalik sinir (3) asilinca reddedilmeli: %v %q", ok, reason)
	}
	if _, ok, _ := l.Acquire(1, now.Add(61*time.Second)); !ok {
		t.Fatal("pencere kayinca yeniden kabul edilmeli")
	}
}
