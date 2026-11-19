// Package scan, fis gorsellerini OCR servisine gonderen istemci (Strategy + fabrika, ocr_engine.go) ve cok
// sayfali taramanin orkestrasyonudur: sinirli paralellik, sayfa basina zaman asimi/yeniden deneme, sayfa
// metinlerinin birlestirilmesi (receiptparse.MergePageTexts) ve kullanici basina tarama siniri.
package scan

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"fissio/expense/internal/receiptparse"
)

// Tarama (OCR) zaman ve paralellik ayarlari. Degiskenler yalnizca testlerin kisa degerler vermesi icindir.
var (
	// scanTotalTimeout: bir /receipts/scan isteginin tum OCR isi icin ust siniri (mobil istemci 120 sn'de vazgecer).
	scanTotalTimeout = 90 * time.Second
	// scanPageTimeout: tek sayfanin tek OCR denemesi icin sinir.
	scanPageTimeout = 30 * time.Second
	// scanParallelism: ayni anda OCR'a giden sayfa sayisi (OCR servisinin OCR_MAX_CONCURRENT varsayilani ile ayni).
	scanParallelism = 2
	// scanRetryPause: gecici hatada yeniden denemeden onceki bekleme.
	scanRetryPause = 300 * time.Millisecond
	// scanMinRetryBudget: yeniden deneme icin kalan sure en az bu kadar olmali.
	scanMinRetryBudget = 3 * time.Second
)

// PageResult tek sayfanin sonucudur; Err != nil ise sayfa okunamamistir.
type PageResult struct {
	Res *OcrExtractionResult
	Err error
}

// ocrPage tek sayfayi okur: deneme basina scanPageTimeout, gecici hatada (baglanti, 5xx, zaman asimi) kalan sure
// elveriyorsa bir kez daha dener. Gecersiz gorsel (400) tekrar denenmez.
func ocrPage(ctx context.Context, engine OcrEngine, img []byte) (*OcrExtractionResult, error) {
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		pctx, cancel := context.WithTimeout(ctx, scanPageTimeout)
		res, err := engine.ExtractText(pctx, img)
		cancel()
		if err == nil {
			return res, nil
		}
		lastErr = err
		if errors.Is(err, ErrInvalidOcrInput) || ctx.Err() != nil {
			return nil, err
		}
		if dl, ok := ctx.Deadline(); ok && time.Until(dl) < scanMinRetryBudget {
			return nil, err
		}
		select {
		case <-time.After(scanRetryPause):
		case <-ctx.Done():
			return nil, lastErr
		}
	}
	return nil, lastErr
}

// Run sayfalari en cok scanParallelism paralellikle okur; sonuc dizisi sayfa sirasini korur. Her sayfa
// bellekten islendikten hemen sonra silinir (gorsel bellekte tutulmaz).
func Run(parent context.Context, engine OcrEngine, pages [][]byte) []PageResult {
	ctx, cancel := context.WithTimeout(parent, scanTotalTimeout)
	defer cancel()
	out := make([]PageResult, len(pages))
	sem := make(chan struct{}, max(1, scanParallelism))
	var wg sync.WaitGroup
	for i := range pages {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			defer clear(pages[i])
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				out[i].Err = ctx.Err()
				return
			}
			res, err := ocrPage(ctx, engine, pages[i])
			out[i] = PageResult{Res: res, Err: err}
		}(i)
	}
	wg.Wait()
	return out
}

// Assemble basarili sayfalari birlestirir; okunamayan sayfalarin 1 tabanli numaralari failed'da doner.
// allInvalid: hicbir sayfa okunamadi ve hepsi gecersiz gorsel hatasi (istemci hatasi, 400).
func Assemble(results []PageResult) (agg OcrExtractionResult, failed []int, allInvalid bool) {
	agg = OcrExtractionResult{PageCount: len(results), PageTexts: make([]string, len(results))}
	var texts []string
	confSum, ok, invalid := 0.0, 0, 0
	for i, r := range results {
		if r.Err != nil || r.Res == nil {
			failed = append(failed, i+1)
			if errors.Is(r.Err, ErrInvalidOcrInput) {
				invalid++
			}
			continue
		}
		texts = append(texts, r.Res.RawText)
		agg.PageTexts[i] = r.Res.RawText
		agg.Blocks = append(agg.Blocks, r.Res.Blocks...)
		agg.ElapsedMs += r.Res.ElapsedMs
		confSum += r.Res.Confidence
		if ok == 0 {
			agg.Engine, agg.ModelVersion, agg.Metadata = r.Res.Engine, r.Res.ModelVersion, r.Res.Metadata
		}
		ok++
	}
	if ok > 0 {
		agg.RawText = receiptparse.MergePageTexts(texts)
		agg.Confidence = confSum / float64(ok)
	}
	agg.IsEmpty = strings.TrimSpace(agg.RawText) == ""
	if agg.Blocks == nil {
		agg.Blocks = []OcrTextBlock{}
	}
	return agg, failed, ok == 0 && invalid == len(results)
}

// Limiter kullanici basina es zamanli tarama sayisini ve dakikadaki tarama sayisini sinirlar: yetkili bir kullanici
// OCR servisini (CPU yogun) tek basina dolduramaz. Bellek ici ve surec basinadir (tek expense kopyasi varsayimi).
type Limiter struct {
	mu        sync.Mutex
	maxActive int
	perMinute int
	active    map[int64]int
	recent    map[int64][]time.Time
}

func NewLimiter(maxActive, perMinute int) *Limiter {
	return &Limiter{maxActive: maxActive, perMinute: perMinute, active: map[int64]int{}, recent: map[int64][]time.Time{}}
}

// Acquire izin verirse release'i doner; reddederse ok=false ve neden ("busy" | "rate").
func (l *Limiter) Acquire(uid int64, now time.Time) (release func(), ok bool, reason string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.active[uid] >= l.maxActive {
		return nil, false, "busy"
	}
	if len(l.recent) > 2048 { // bellek: uzun suredir tarama yapmayan kullanicilari temizle
		for uid, ts := range l.recent {
			if len(ts) == 0 || !ts[len(ts)-1].After(now.Add(-time.Minute)) {
				delete(l.recent, uid)
			}
		}
	}
	cut := now.Add(-time.Minute)
	kept := l.recent[uid][:0]
	for _, t := range l.recent[uid] {
		if t.After(cut) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= l.perMinute {
		l.recent[uid] = kept
		return nil, false, "rate"
	}
	l.recent[uid] = append(kept, now)
	l.active[uid]++
	return func() {
		l.mu.Lock()
		defer l.mu.Unlock()
		if l.active[uid]--; l.active[uid] <= 0 {
			delete(l.active, uid)
		}
	}, true, ""
}

var DefaultLimiter = NewLimiter(2, 30)
