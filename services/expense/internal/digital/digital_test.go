package digital

import (
	"encoding/base64"
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
	t.Run("başka gönderici: link yoksa reddedilir", func(t *testing.T) {
		fake := "Onay kodu: 123456789\nhttps://evil.io/mail/vf-abc\nToplam 1,00"
		if _, ok := DetectGmailConfirmation("evil@example.com", fake, "", ""); ok {
			t.Error("sahte gönderici kabul edildi")
		}
		if _, ok := DetectGmailConfirmation("forwarding-noreply@google.com.evil.io", fake, "", ""); ok {
			t.Error("benzer alan adı kabul edildi")
		}
		if _, ok := DetectGmailConfirmation("forwarding-noreply@evil-google.com", fake, "", ""); ok {
			t.Error("evil-google.com kabul edildi")
		}
	})
	t.Run("gönderici ne olursa olsun doğrulanmış Google bağlantısı onay sayılır", func(t *testing.T) {
		g, ok := DetectGmailConfirmation("", body, "", "")
		if !ok || g.Link == "" || g.Code != "123456789" {
			t.Fatalf("%+v ok=%v", g, ok)
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
	t.Run("kod yoksa yalnızca bağlantı döner", func(t *testing.T) {
		g, ok := DetectGmailConfirmation("forwarding-noreply@google.com", "Onaylamak için: https://mail-settings.google.com/mail/vf-%5BA%5D-q", "", "")
		if !ok || g.Code != "" || g.Link != "https://mail-settings.google.com/mail/vf-%5BA%5D-q" {
			t.Fatalf("%+v ok=%v", g, ok)
		}
	})
	t.Run("Google forwarding göndericisi kod/bağlantı olmasa da fiş değildir", func(t *testing.T) {
		g, ok := DetectGmailConfirmation("forwarding-noreply@google.com", "merhaba", "", "")
		if !ok || g.Code != "" || g.Link != "" {
			t.Fatalf("%+v ok=%v", g, ok)
		}
	})
	t.Run("alakasız mail ve sıradan Google fişi onay sayılmaz", func(t *testing.T) {
		if _, ok := DetectGmailConfirmation("shop@example.com", "Toplam 1,00 https://mail.google.com/mail/u/0/#inbox", "", ""); ok {
			t.Error("alakasız mail kabul edildi")
		}
		if _, ok := DetectGmailConfirmation("googleplay-noreply@google.com", "Sipariş 123456789 Toplam 29,99 TL", "", ""); ok {
			t.Error("Google Play fişi onay sayıldı")
		}
	})
	t.Run("konudaki (#kod) yakalanır", func(t *testing.T) {
		g, ok := DetectGmailConfirmation("forwarding-noreply@google.com", "", "", "", "(#246813579) Gmail Yönlendirme Onayı")
		if !ok || g.Code != "246813579" {
			t.Fatalf("%+v ok=%v", g, ok)
		}
	})
}

// Türkçe Gmail yönlendirme onayı: RFC 2047 başlıklar, multipart/alternative, quoted-printable gövde, `=\r\n` ile bölünmüş
// uzun URL ve `=3D`. ParseEML → DetectGmailConfirmation uçtan uca.
const trGmailConfirmationEML = "Delivered-To: x@fissio.dev\r\n" +
	"From: =?UTF-8?Q?Gmail_Ekibi?= <forwarding-noreply@google.com>\r\n" +
	"To: x@fissio.dev\r\n" +
	"Subject: =?UTF-8?Q?(#123456789)_Gmail_Y=C3=B6nlendirme_Onay=C4=B1_-_ahmet@gmail.com?=\r\n" +
	"MIME-Version: 1.0\r\n" +
	"Content-Type: multipart/alternative; boundary=\"b1\"\r\n\r\n" +
	"--b1\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" +
	"ahmet@gmail.com adresi, e-postalar=C4=B1n=C4=B1z=C4=B1 x@fissio.dev adresine y=C3=B6nlendirmek=\r\n" +
	" istiyor.\r\n\r\n" +
	"Onay kodu: 123456789\r\n\r\n" +
	"Bu iste=C4=9Fi onaylamak i=C3=A7in bu ba=C4=9Flant=C4=B1ya t=C4=B1klay=C4=B1n:\r\n" +
	"https://mail-settings.google.com/mail/vf-%5BANGjdJBqL1zXh0p9YkE-aBcDeFgHiJkLmNoPqRs=\r\n" +
	"TuVwXyZ%5D-AbCdEfGhIjKlMnOpQrStUvWxYz?a=3Db&c=3Dd\r\n" +
	"--b1\r\nContent-Type: text/html; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" +
	"<p>Onay kodu: <b>123456789</b></p><a href=3D\"https://mail-settings.google.com/mail/vf-%5BANGjdJBqL1zXh0p9YkE-aBcDeFgHiJkLmNoPqRs=\r\n" +
	"TuVwXyZ%5D-AbCdEfGhIjKlMnOpQrStUvWxYz?a=3Db&amp;c=3Dd\">Onayla</a>\r\n" +
	"--b1--\r\n"

func TestDetectGmailConfirmationTurkishMIME(t *testing.T) {
	const wantLink = "https://mail-settings.google.com/mail/vf-%5BANGjdJBqL1zXh0p9YkE-aBcDeFgHiJkLmNoPqRsTuVwXyZ%5D-AbCdEfGhIjKlMnOpQrStUvWxYz?a=b&c=d"

	t.Run("ayrıştırılmış mesaj", func(t *testing.T) {
		m, err := ParseEML([]byte(trGmailConfirmationEML))
		if err != nil {
			t.Fatal(err)
		}
		g, ok := DetectGmailConfirmation(m.From, m.Text, HTMLToText(m.HTML), m.HTML, m.Subject)
		if !ok || g.Code != "123456789" || g.Link != wantLink {
			t.Fatalf("%+v ok=%v\nfrom=%q text=%q", g, ok, m.From, m.Text)
		}
	})
	t.Run("yalnızca ham MIME (sağlayıcı ayrıştırmadı)", func(t *testing.T) {
		g, ok := DetectGmailConfirmation("", "", "", "", trGmailConfirmationEML)
		if !ok || g.Code != "123456789" || g.Link != wantLink {
			t.Fatalf("%+v ok=%v", g, ok)
		}
	})
	t.Run("gövde kodlu ama ayrıştırılmamış düz metin", func(t *testing.T) {
		qp := "Onay kodu: 246813579\r\nhttps://mail-settings.google.com/mail/vf-%5BANGjd=\r\nJ%5D-xyz\r\n"
		g, ok := DetectGmailConfirmation("forwarding-noreply@google.com", qp, "", "")
		if !ok || g.Code != "246813579" || g.Link != "https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-xyz" {
			t.Fatalf("%+v ok=%v", g, ok)
		}
	})
	t.Run("base64 gövde", func(t *testing.T) {
		plain := "Onay kodu: 135792468\nhttps://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-b64\n"
		b := base64.StdEncoding.EncodeToString([]byte(plain))
		g, ok := DetectGmailConfirmation("forwarding-noreply@google.com", b, "", "")
		if !ok || g.Code != "135792468" || g.Link != "https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-b64" {
			t.Fatalf("%+v ok=%v", g, ok)
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
