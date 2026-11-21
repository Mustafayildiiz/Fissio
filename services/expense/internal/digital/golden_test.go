package digital

import (
	"bytes"
	"encoding/json"
	"flag"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// -update: html/*.json ve preamble.json içindeki beklenen metinleri Go çıktısıyla yeniden yazar (sonra elle gözden geçirin).
var update = flag.Bool("update", false, "golden beklenen metinlerini yeniden yaz")

const testdataDir = "../../../../testdata"

func loadJSON(t *testing.T, name string, v any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(testdataDir, name))
	if err != nil {
		t.Fatalf("testdata/%s okunamadı: %v", name, err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("testdata/%s ayrıştırılamadı: %v", name, err)
	}
}

func writeJSON(t *testing.T, name string, v any) {
	t.Helper()
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(testdataDir, name), buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func normNL(s string) string { return strings.ReplaceAll(s, "\r\n", "\n") }

type htmlVector struct {
	Name   string `json:"name"`
	Note   string `json:"note"`
	HTML   string `json:"html"`
	Expect struct {
		Text       string `json:"text"`
		OrderID    string `json:"order_id"`
		DocumentNo string `json:"document_no"`
	} `json:"expect"`
}

func TestGoldenHTML(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(testdataDir, "html", "*.json"))
	if len(files) < 7 {
		t.Fatalf("testdata/html/*.json en az 7 vaka olmalı, %d bulundu", len(files))
	}
	for _, f := range files {
		rel := filepath.Join("html", filepath.Base(f))
		var v htmlVector
		loadJSON(t, rel, &v)
		got := StripForwardPreamble(HTMLToText(v.HTML))
		if *update {
			v.Expect.Text = got
			writeJSON(t, rel, v)
			continue
		}
		t.Run(v.Name, func(t *testing.T) {
			if got != v.Expect.Text {
				t.Errorf("metin:\n--- beklenen ---\n%s\n--- gelen ---\n%s", v.Expect.Text, got)
			}
			if id := ExtractOrderID(got); id != v.Expect.OrderID {
				t.Errorf("order_id = %q, beklenen %q", id, v.Expect.OrderID)
			}
			if d := ExtractDocumentNo(got); d != v.Expect.DocumentNo {
				t.Errorf("document_no = %q, beklenen %q", d, v.Expect.DocumentNo)
			}
		})
	}
}

func TestGoldenPreamble(t *testing.T) {
	var g struct {
		Note  string `json:"note"`
		Cases []struct {
			Name string `json:"name"`
			Text string `json:"text"`
			Out  string `json:"out"`
		} `json:"cases"`
	}
	loadJSON(t, "preamble.json", &g)
	if len(g.Cases) < 7 {
		t.Fatalf("en az 7 vaka olmalı: %d", len(g.Cases))
	}
	for i := range g.Cases {
		c := &g.Cases[i]
		got := StripForwardPreamble(c.Text)
		if *update {
			c.Out = got
			continue
		}
		if got != c.Out {
			t.Errorf("%s:\n--- beklenen ---\n%s\n--- gelen ---\n%s", c.Name, c.Out, got)
		}
	}
	if *update {
		writeJSON(t, "preamble.json", g)
	}
}

func TestGoldenIDs(t *testing.T) {
	var g struct {
		Cases []struct {
			Name       string `json:"name"`
			Text       string `json:"text"`
			DocumentNo string `json:"document_no"`
			OrderID    string `json:"order_id"`
		} `json:"cases"`
	}
	loadJSON(t, "digital_ids.json", &g)
	if len(g.Cases) < 15 {
		t.Fatalf("en az 15 vaka olmalı: %d", len(g.Cases))
	}
	for _, c := range g.Cases {
		if got := ExtractDocumentNo(c.Text); got != c.DocumentNo {
			t.Errorf("%s: document_no = %q, beklenen %q", c.Name, got, c.DocumentNo)
		}
		if got := ExtractOrderID(c.Text); got != c.OrderID {
			t.Errorf("%s: order_id = %q, beklenen %q", c.Name, got, c.OrderID)
		}
	}
}

type mergeDoc struct {
	ID         int64    `json:"id"`
	Merchant   string   `json:"merchant"`
	Amount     float64  `json:"amount"`
	Date       string   `json:"date"`
	DocumentNo string   `json:"document_no"`
	OrderID    string   `json:"order_id"`
	Items      []string `json:"items"`
}

func (m mergeDoc) doc() Doc {
	return Doc{ID: m.ID, Merchant: m.Merchant, AmountCents: int64(math.Round(m.Amount * 100)), Date: m.Date,
		DocumentNo: m.DocumentNo, OrderID: m.OrderID, Items: m.Items}
}

func TestGoldenMergeDecision(t *testing.T) {
	var g struct {
		Cases []struct {
			Name       string     `json:"name"`
			Incoming   mergeDoc   `json:"incoming"`
			Candidates []mergeDoc `json:"candidates"`
			Expect     struct {
				Action   string `json:"action"`
				TargetID int64  `json:"target_id"`
			} `json:"expect"`
		} `json:"cases"`
	}
	loadJSON(t, "merge_decision.json", &g)
	if len(g.Cases) < 18 {
		t.Fatalf("en az 18 vaka olmalı: %d", len(g.Cases))
	}
	for _, c := range g.Cases {
		var cands []Doc
		for _, m := range c.Candidates {
			cands = append(cands, m.doc())
		}
		d := DecideMerge(c.Incoming.doc(), cands)
		if d.Action != c.Expect.Action || d.TargetID != c.Expect.TargetID {
			t.Errorf("%s: karar = %+v, beklenen %s/%d", c.Name, d, c.Expect.Action, c.Expect.TargetID)
		}
	}
}

func TestGoldenEML(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(testdataDir, "eml", "*.json"))
	if len(files) < 5 {
		t.Fatalf("testdata/eml/*.json en az 5 vaka olmalı: %d", len(files))
	}
	for _, f := range files {
		var v struct {
			Name   string `json:"name"`
			EML    string `json:"eml"`
			Expect struct {
				Subject    string   `json:"subject"`
				From       string   `json:"from"`
				MessageID  string   `json:"message_id"`
				Text       string   `json:"text"`
				HTML       string   `json:"html"`
				PDFNames   []string `json:"pdf_names"`
				Recipients []string `json:"recipients"`
			} `json:"expect"`
		}
		loadJSON(t, filepath.Join("eml", filepath.Base(f)), &v)
		t.Run(v.Name, func(t *testing.T) {
			m, err := ParseEML([]byte(v.EML))
			if err != nil {
				t.Fatal(err)
			}
			if m.Subject != v.Expect.Subject || m.From != v.Expect.From || m.MessageID != v.Expect.MessageID {
				t.Errorf("başlıklar: %q / %q / %q", m.Subject, m.From, m.MessageID)
			}
			if normNL(m.Text) != v.Expect.Text {
				t.Errorf("text = %q, beklenen %q", normNL(m.Text), v.Expect.Text)
			}
			if normNL(m.HTML) != v.Expect.HTML {
				t.Errorf("html = %q, beklenen %q", normNL(m.HTML), v.Expect.HTML)
			}
			var names []string
			for _, a := range m.PDFs {
				names = append(names, a.Name)
			}
			if strings.Join(names, ",") != strings.Join(v.Expect.PDFNames, ",") {
				t.Errorf("pdf = %v, beklenen %v", names, v.Expect.PDFNames)
			}
			if strings.Join(m.Recipients, ",") != strings.Join(v.Expect.Recipients, ",") {
				t.Errorf("alıcılar = %v, beklenen %v", m.Recipients, v.Expect.Recipients)
			}
		})
	}
}
