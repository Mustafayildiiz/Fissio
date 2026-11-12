package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// OcrTextBlock represents a single recognized text box from the OCR engine.
type OcrTextBlock struct {
	Text       string      `json:"text"`
	Confidence float64     `json:"confidence"`
	BBox       [][]float64 `json:"bbox,omitempty"`
}

// OcrExtractionResult represents the standardized output returned by an OcrEngine.
type OcrExtractionResult struct {
	RawText      string         `json:"raw_text"`
	Blocks       []OcrTextBlock `json:"blocks"`
	Confidence   float64        `json:"confidence"`
	Engine       string         `json:"engine"`
	ModelVersion string         `json:"model_version"`
	ElapsedMs    float64        `json:"elapsed_ms"`
	IsEmpty      bool           `json:"is_empty"`
}

// OcrEngine defines the Strategy Pattern interface for OCR providers in the Expense service.
type OcrEngine interface {
	Name() string
	ExtractText(ctx context.Context, imageBase64 string) (*OcrExtractionResult, error)
}

var (
	ErrUnknownOcrEngine = errors.New("unknown ocr engine")
	ErrOcrUnavailable   = errors.New("ocr service unavailable")
	ErrInvalidOcrInput  = errors.New("invalid ocr image input")
)

// RemoteMicroserviceOcrEngine delegates OCR extraction to the Python OCR microservice
// for a specific strategy identifier ('paddleocr', 'custom', etc.).
type RemoteMicroserviceOcrEngine struct {
	engineName string
	baseURL    string
	client     *http.Client
}

func NewRemoteMicroserviceOcrEngine(engineName, baseURL string) *RemoteMicroserviceOcrEngine {
	if baseURL == "" {
		baseURL = "http://ocr:8080"
	}
	return &RemoteMicroserviceOcrEngine{
		engineName: engineName,
		baseURL:    strings.TrimRight(baseURL, "/"),
		client:     &http.Client{Timeout: 25 * time.Second},
	}
}

func (e *RemoteMicroserviceOcrEngine) Name() string { return e.engineName }

func (e *RemoteMicroserviceOcrEngine) ExtractText(ctx context.Context, imageBase64 string) (*OcrExtractionResult, error) {
	if strings.TrimSpace(imageBase64) == "" {
		return nil, ErrInvalidOcrInput
	}
	reqBody, err := json.Marshal(map[string]string{
		"image_base64": imageBase64,
		"engine":       e.engineName,
	})
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.baseURL+"/ocr/extract", bytes.NewReader(reqBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-OCR-Engine", e.engineName)

	resp, err := e.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrOcrUnavailable, err)
	}
	defer resp.Body.Close()

	bodyBytes, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return nil, err
	}

	if resp.StatusCode == http.StatusBadRequest {
		return nil, ErrInvalidOcrInput
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("ocr engine returned status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var out OcrExtractionResult
	if err := json.Unmarshal(bodyBytes, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// OcrEngineFactory manages registered OcrEngine strategies and resolves them at runtime.
type OcrEngineFactory struct {
	mu            sync.RWMutex
	defaultEngine string
	engines       map[string]OcrEngine
	aliases       map[string]string
}

func NewOcrEngineFactory(defaultEngine, serviceURL string) *OcrEngineFactory {
	if defaultEngine == "" {
		defaultEngine = "paddleocr"
	}
	f := &OcrEngineFactory{
		defaultEngine: strings.ToLower(strings.TrimSpace(defaultEngine)),
		engines:       make(map[string]OcrEngine),
		aliases:       make(map[string]string),
	}
	f.Register("paddleocr", NewRemoteMicroserviceOcrEngine("paddleocr", serviceURL), "paddle", "ppocr", "pp-ocrv4")
	f.Register("custom", NewRemoteMicroserviceOcrEngine("custom", serviceURL), "custom_ocr", "inhouse")
	return f
}

func NewOcrEngineFactoryFromEnv() *OcrEngineFactory {
	return NewOcrEngineFactory(
		os.Getenv("OCR_ENGINE"),
		os.Getenv("OCR_SERVICE_URL"),
	)
}

func (f *OcrEngineFactory) Register(name string, engine OcrEngine, aliases ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	canonical := strings.ToLower(strings.TrimSpace(name))
	f.engines[canonical] = engine
	f.aliases[canonical] = canonical
	for _, a := range aliases {
		norm := strings.ToLower(strings.TrimSpace(a))
		if norm != "" {
			f.aliases[norm] = canonical
		}
	}
}

func (f *OcrEngineFactory) Resolve(requested string) (OcrEngine, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()
	key := strings.ToLower(strings.TrimSpace(requested))
	if key == "" {
		key = f.defaultEngine
	}
	canonical, ok := f.aliases[key]
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrUnknownOcrEngine, requested)
	}
	eng, ok := f.engines[canonical]
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrUnknownOcrEngine, requested)
	}
	return eng, nil
}

