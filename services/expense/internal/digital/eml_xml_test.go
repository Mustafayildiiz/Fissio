package digital

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"strings"
	"testing"
)

func b64Lines(b []byte) string {
	s := base64.StdEncoding.EncodeToString(b)
	var out []string
	for len(s) > 76 {
		out = append(out, s[:76])
		s = s[76:]
	}
	return strings.Join(append(out, s), "\r\n")
}

// ABLUKA tarzı e-Arşiv maili: multipart/mixed → (multipart/related → multipart/alternative: text+html) + PDF + XML.
func arsivMIME(xml []byte, pdf []byte) string {
	return "From: =?UTF-8?Q?ABLUKA_e-Ar=C5=9Fiv?= <earsiv@abluka.example>\r\n" +
		"To: x@fissio.dev\r\n" +
		"Subject: ABLUKA e-Ar=?UTF-8?Q?=C5=9Fiv?= Faturanız\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: multipart/mixed; boundary=\"mix\"\r\n\r\n" +
		"--mix\r\nContent-Type: multipart/related; boundary=\"rel\"\r\n\r\n" +
		"--rel\r\nContent-Type: multipart/alternative; boundary=\"alt\"\r\n\r\n" +
		"--alt\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nFaturanız ektedir.\r\n" +
		"--alt\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<p>Faturanız ektedir.</p>\r\n" +
		"--alt--\r\n" +
		"--rel--\r\n" +
		"--mix\r\nContent-Type: application/pdf; name=\"fatura.pdf\"\r\nContent-Transfer-Encoding: base64\r\n" +
		"Content-Disposition: attachment; filename=\"fatura.pdf\"\r\n\r\n" + b64Lines(pdf) + "\r\n" +
		"--mix\r\nContent-Type: application/xml; name=\"fatura.xml\"\r\nContent-Transfer-Encoding: base64\r\n" +
		"Content-Disposition: attachment; filename=\"fatura.xml\"\r\n\r\n" + b64Lines(xml) + "\r\n" +
		"--mix--\r\n"
}

func TestParseEMLMultipartMixedRelatedWithXMLAndPDF(t *testing.T) {
	m, err := ParseEML([]byte(arsivMIME([]byte(ublSample), []byte("%PDF-1.4 fake"))))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.XMLs) != 1 || m.XMLs[0].Name != "fatura.xml" {
		t.Fatalf("xmls: %+v", m.XMLs)
	}
	if len(m.PDFs) != 1 || m.PDFs[0].Name != "fatura.pdf" {
		t.Fatalf("pdfs: %+v", m.PDFs)
	}
	if !strings.Contains(m.HTML, "Faturan") || !strings.Contains(m.Text, "ektedir") {
		t.Fatalf("bodies: %q / %q", m.Text, m.HTML)
	}
	inv, err := ParseUBL(m.XMLs[0].Data)
	if err != nil || inv.AmountCents != 21600 {
		t.Fatalf("attached xml must round-trip: %v %+v", err, inv)
	}
}

func TestParseEMLXMLNamedOctetStreamAndZip(t *testing.T) {
	var zb bytes.Buffer
	zw := zip.NewWriter(&zb)
	f, _ := zw.Create("klasor/fatura.xml")
	_, _ = f.Write([]byte(ublSample))
	_ = zw.Close()
	raw := "From: a@b.example\r\nTo: x@fissio.dev\r\nSubject: s\r\nMIME-Version: 1.0\r\n" +
		"Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n" +
		"--m\r\nContent-Type: text/plain\r\n\r\nmerhaba\r\n" +
		"--m\r\nContent-Type: application/octet-stream; name=\"x.xml\"\r\nContent-Transfer-Encoding: base64\r\n\r\n" +
		b64Lines([]byte(ublSample)) + "\r\n" +
		"--m\r\nContent-Type: application/zip; name=\"z.zip\"\r\nContent-Transfer-Encoding: base64\r\n\r\n" +
		b64Lines(zb.Bytes()) + "\r\n--m--\r\n"
	m, err := ParseEML([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.XMLs) != 2 || m.XMLs[1].Name != "fatura.xml" {
		t.Fatalf("xmls: %+v", m.XMLs)
	}
}

func TestParseEMLXMLLimitPerMail(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("From: a@b.example\r\nSubject: s\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"m\"\r\n\r\n")
	for i := 0; i < 9; i++ {
		sb.WriteString("--m\r\nContent-Type: application/xml; name=\"a.xml\"\r\n\r\n<Invoice/>\r\n")
	}
	sb.WriteString("--m--\r\n")
	m, err := ParseEML([]byte(sb.String()))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.XMLs) != maxXMLsPerMail {
		t.Fatalf("len = %d", len(m.XMLs))
	}
}
