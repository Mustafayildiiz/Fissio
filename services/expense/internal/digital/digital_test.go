package digital

import (
	"errors"
	"testing"
)

func TestDetectGmailConfirmation(t *testing.T) {
	body := "ahmet@gmail.com adresinden gelen istek: mail yönlendirme.\nOnay kodu: 123456789\n" +
		"Onaylamak için bağlantıya tıklayın: https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-abc?x=1&amp;y=2\n"
	html := `<p>Confirmation code: 987654321</p><a href="https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-zzz">Confirm</a>`

	t.Run("türkçe metin", func(t *testing.T) {
		g, ok := DetectGmailConfirmation("Gmail Team <forwarding-noreply@google.com>", body, "", "")
		if !ok || g.Code != "123456789" {
			t.Fatalf("beklenen kod 123456789, gelen %+v ok=%v", g, ok)
		}
		if g.Link != "https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-abc?x=1&y=2" {
			t.Errorf("bağlantı: %q", g.Link)
		}
	})
	t.Run("html href", func(t *testing.T) {
		g, ok := DetectGmailConfirmation("forwarding-noreply@google.com", "", HTMLToText(html), html)
		if !ok || g.Code != "987654321" || g.Link == "" {
			t.Fatalf("%+v ok=%v", g, ok)
		}
	})
	t.Run("başka gönderici reddedilir", func(t *testing.T) {
		if _, ok := DetectGmailConfirmation("evil@example.com", body, "", ""); ok {
			t.Error("sahte gönderici kabul edildi")
		}
		if _, ok := DetectGmailConfirmation("forwarding-noreply@google.com.evil.io", body, "", ""); ok {
			t.Error("benzer alan adı kabul edildi")
		}
	})
	t.Run("sahte bağlantı ana makinesi atılır, kod kalır", func(t *testing.T) {
		evil := "Code: 123456789\nhttps://mail-settings.google.com.evil.io/mail/vf-abc\nhttps://evil.io/mail/vf-abc\nhttp://mail.google.com/mail/vf-abc"
		g, ok := DetectGmailConfirmation("forwarding-noreply@google.com", evil, "", "")
		if !ok || g.Code != "123456789" {
			t.Fatalf("%+v ok=%v", g, ok)
		}
		if g.Link != "" {
			t.Errorf("güvenilmeyen bağlantı döndü: %q", g.Link)
		}
	})
	t.Run("kod yoksa ok=false", func(t *testing.T) {
		if _, ok := DetectGmailConfirmation("forwarding-noreply@google.com", "merhaba", "", ""); ok {
			t.Error("kodsuz mail kabul edildi")
		}
	})
}

func TestPDFPageTextsGarbageDoesNotPanic(t *testing.T) {
	for _, data := range [][]byte{nil, []byte("not a pdf"), []byte("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF"), make([]byte, 1<<10)} {
		pages, err := PDFPageTexts(data)
		if err == nil && HasUsableTextLayer(pages) {
			t.Errorf("çöp veri kullanılabilir metin üretti: %q", pages)
		}
		if err != nil && !errors.Is(err, ErrPDFUnreadable) {
			t.Errorf("hata ErrPDFUnreadable olmalı: %v", err)
		}
	}
}

func TestReceiptTextPriority(t *testing.T) {
	goodPDF := func([]byte) ([]string, error) {
		return []string{"Köşebaşı Döner Restoran A.Ş. Fatura Ödenecek Tutar 210,00 TL satır satır metin katmanı vardır"}, nil
	}
	emptyPDF := func([]byte) ([]string, error) { return []string{""}, nil }
	brokenPDF := func([]byte) ([]string, error) { return nil, ErrPDFUnreadable }
	pdf := []Attachment{{Name: "f.pdf", Data: []byte("x")}}

	t.Run("PDF metin katmanı HTML'e baskın", func(t *testing.T) {
		txt, src := ReceiptText(&Message{PDFs: pdf, HTML: "<p>Toplam 1,00</p>"}, goodPDF)
		if src != SourcePDF || txt == "" {
			t.Errorf("src=%s", src)
		}
	})
	t.Run("taranmış PDF → HTML'e düşer", func(t *testing.T) {
		txt, src := ReceiptText(&Message{PDFs: pdf, HTML: "<p>Market</p><p>Toplam 1,00</p>"}, emptyPDF)
		if src != SourceHTML || txt != "Market\nToplam 1,00" {
			t.Errorf("src=%s txt=%q", src, txt)
		}
	})
	t.Run("yalnız okunamayan PDF", func(t *testing.T) {
		_, src := ReceiptText(&Message{PDFs: pdf}, brokenPDF)
		if src != SourcePDFUnreadable {
			t.Errorf("src=%s", src)
		}
	})
	t.Run("düz metin ve önsöz", func(t *testing.T) {
		txt, src := ReceiptText(&Message{Text: "---------- Forwarded message ---------\nFrom: a@b.c\nSubject: x\n\nMigros\nToplam 5,00"}, nil)
		if src != SourceText || txt != "Migros\nToplam 5,00" {
			t.Errorf("src=%s txt=%q", src, txt)
		}
	})
	t.Run("boş", func(t *testing.T) {
		if _, src := ReceiptText(&Message{}, nil); src != SourceEmpty {
			t.Errorf("src=%s", src)
		}
	})
}

func TestNormalizeDocumentNoAndOrderID(t *testing.T) {
	if got := NormalizeDocumentNo("3F2A9C1E-5B7D-4E8A-9C3D-1A2B3C4D5E6F"); got != "3f2a9c1e-5b7d-4e8a-9c3d-1a2b3c4d5e6f" {
		t.Errorf("ettn: %q", got)
	}
	if got := NormalizeDocumentNo("1234567890_gib2026000000123"); got != "1234567890_GIB2026000000123" {
		t.Errorf("vkn_no: %q", got)
	}
	for _, bad := range []string{"", "abc", "12345", "0468"} {
		if NormalizeDocumentNo(bad) != "" {
			t.Errorf("%q geçersiz olmalı", bad)
		}
	}
	if NormalizeOrderID(" gpa.3345-1234 ") != "GPA.3345-1234" || NormalizeOrderID("ab") != "" || NormalizeOrderID("-abc1") != "" {
		t.Error("order id normalizasyonu")
	}
}
