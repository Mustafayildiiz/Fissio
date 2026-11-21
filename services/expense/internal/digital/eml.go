package digital

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"net/textproto"
	"path"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/text/encoding/htmlindex"
)

const (
	maxEMLBytes        = 30 << 20
	maxAttachmentBytes = 20 << 20
	maxPDFsPerMail     = 5
	maxMIMEDepth       = 6
)

// Attachment e-postadan çıkan PDF eki (zip içinden gelenler dahil).
type Attachment struct {
	Name string
	Data []byte
}

// Message ayrıştırılmış e-posta: görüntülenecek metin/HTML gövdeler ve PDF ekleri.
type Message struct {
	Subject   string
	From      string
	MessageID string
	// Date: Date başlığı (sıfır değer = yok/ayrıştırılamadı); fişte tarih bulunamazsa kullanılır.
	Date time.Time
	// Recipients: Delivered-To, X-Forwarded-To, X-Original-To, To, Cc başlıklarındaki adresler (alias çözümü için).
	Recipients []string
	Text       string // text/plain gövde(ler)
	HTML       string // text/html gövde(ler) (ham)
	PDFs       []Attachment
	// XMLs: .xml ekleri (UBL-TR e-Fatura/e-Arşiv; zip içinden gelenler dahil). Ayrıştırma ParseUBL'dedir.
	XMLs []Attachment
}

var wordDecoder = &mime.WordDecoder{CharsetReader: func(charset string, input io.Reader) (io.Reader, error) {
	enc, err := htmlindex.Get(charset)
	if err != nil {
		return nil, err
	}
	return enc.NewDecoder().Reader(input), nil
}}

func decodeHeader(s string) string {
	d, err := wordDecoder.DecodeHeader(s)
	if err != nil {
		return s
	}
	return d
}

// decodeCharset etikete göre baytları UTF-8 metne çevirir (etiket yoksa geçerli UTF-8 değilse windows-1254 denenir).
func decodeCharset(label string, b []byte) string {
	label = strings.ToLower(strings.TrimSpace(label))
	if label == "" || label == "utf-8" || label == "utf8" || label == "us-ascii" {
		if utf8.Valid(b) {
			return string(b)
		}
		label = "windows-1254"
	}
	enc, err := htmlindex.Get(label)
	if err != nil {
		return string(bytes.ToValidUTF8(b, []byte("?")))
	}
	out, err := enc.NewDecoder().Bytes(b)
	if err != nil {
		return string(bytes.ToValidUTF8(b, []byte("?")))
	}
	return string(out)
}

// ParseEML ham RFC 5322/MIME iletisini ayrıştırır. multipart, message/rfc822 (ek olarak iletilmiş mail),
// quoted-printable/base64, Türkçe karakter kümeleri ve PDF / zip içindeki PDF ekleri desteklenir.
func ParseEML(raw []byte) (*Message, error) {
	if len(raw) > maxEMLBytes {
		return nil, errors.New("eml too large")
	}
	msg, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	m := &Message{
		Subject:   decodeHeader(msg.Header.Get("Subject")),
		From:      decodeHeader(msg.Header.Get("From")),
		MessageID: strings.TrimSpace(msg.Header.Get("Message-Id")),
	}
	if t, err := mail.ParseDate(msg.Header.Get("Date")); err == nil {
		m.Date = t
	}
	h := textproto.MIMEHeader(msg.Header)
	m.collectRecipients(h)
	m.walk(h, msg.Body, 0)
	m.Text = strings.TrimSpace(m.Text)
	m.HTML = strings.TrimSpace(m.HTML)
	return m, nil
}

func (m *Message) collectRecipients(h textproto.MIMEHeader) {
	for _, k := range []string{"Delivered-To", "X-Forwarded-To", "X-Original-To", "To", "Cc"} {
		for _, v := range h[textproto.CanonicalMIMEHeaderKey(k)] {
			if list, err := mail.ParseAddressList(decodeHeader(v)); err == nil {
				for _, a := range list {
					m.Recipients = append(m.Recipients, strings.ToLower(a.Address))
				}
				continue
			}
			for _, f := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ';' || r == ' ' || r == '<' || r == '>' }) {
				if strings.Contains(f, "@") {
					m.Recipients = append(m.Recipients, strings.ToLower(strings.Trim(f, "\"")))
				}
			}
		}
	}
}

func decodeBody(h textproto.MIMEHeader, r io.Reader) ([]byte, error) {
	r = io.LimitReader(r, maxEMLBytes)
	switch strings.ToLower(strings.TrimSpace(h.Get("Content-Transfer-Encoding"))) {
	case "base64":
		r = base64.NewDecoder(base64.StdEncoding, &stripWS{r})
	case "quoted-printable":
		r = quotedprintable.NewReader(r)
	}
	return io.ReadAll(r)
}

// stripWS base64 gövdedeki satır sonlarını/boşlukları yutar.
type stripWS struct{ r io.Reader }

func (s *stripWS) Read(p []byte) (int, error) {
	n, err := s.r.Read(p)
	j := 0
	for i := 0; i < n; i++ {
		if p[i] != '\r' && p[i] != '\n' && p[i] != ' ' && p[i] != '\t' {
			p[j] = p[i]
			j++
		}
	}
	return j, err
}

func (m *Message) walk(h textproto.MIMEHeader, body io.Reader, depth int) {
	if depth > maxMIMEDepth {
		return
	}
	ct := h.Get("Content-Type")
	mt, params, err := mime.ParseMediaType(ct)
	if err != nil || mt == "" {
		mt, params = "text/plain", map[string]string{}
	}
	mt = strings.ToLower(mt)
	disp, dparams, _ := mime.ParseMediaType(h.Get("Content-Disposition"))
	name := decodeHeader(firstNonEmpty(dparams["filename"], params["name"]))

	switch {
	case strings.HasPrefix(mt, "multipart/"):
		mr := multipart.NewReader(body, params["boundary"])
		for i := 0; i < 200; i++ {
			p, err := mr.NextRawPart()
			if err != nil {
				return
			}
			m.walk(p.Header, p, depth+1)
		}
	case mt == "message/rfc822":
		data, err := decodeBody(h, body)
		if err != nil {
			return
		}
		inner, err := mail.ReadMessage(bytes.NewReader(data))
		if err != nil {
			return
		}
		ih := textproto.MIMEHeader(inner.Header)
		m.collectRecipients(ih)
		m.walk(ih, inner.Body, depth+1)
	case mt == "application/pdf" || (strings.HasSuffix(strings.ToLower(name), ".pdf") && !strings.HasPrefix(mt, "text/")):
		m.addPDF(name, h, body)
	case mt == "application/zip" || mt == "application/x-zip-compressed" || strings.HasSuffix(strings.ToLower(name), ".zip"):
		data, err := decodeBody(h, body)
		if err != nil || len(data) > maxAttachmentBytes {
			return
		}
		m.PDFs = append(m.PDFs, ExtractZipPDFs(data, maxPDFsPerMail-len(m.PDFs))...)
		m.XMLs = append(m.XMLs, ExtractZipXMLs(data, maxXMLsPerMail-len(m.XMLs))...)
	case mt == "application/xml" || mt == "text/xml" || strings.HasSuffix(strings.ToLower(name), ".xml"):
		m.addXML(name, h, body)
	case mt == "text/plain" || mt == "text/html":
		if strings.EqualFold(disp, "attachment") && name != "" {
			return
		}
		data, err := decodeBody(h, body)
		if err != nil {
			return
		}
		s := decodeCharset(params["charset"], data)
		if mt == "text/html" {
			m.HTML += s + "\n"
		} else {
			m.Text += s + "\n"
		}
	}
}

func (m *Message) addPDF(name string, h textproto.MIMEHeader, body io.Reader) {
	if len(m.PDFs) >= maxPDFsPerMail {
		return
	}
	data, err := decodeBody(h, body)
	if err != nil || len(data) == 0 || len(data) > maxAttachmentBytes {
		return
	}
	m.PDFs = append(m.PDFs, Attachment{Name: name, Data: data})
}

func (m *Message) addXML(name string, h textproto.MIMEHeader, body io.Reader) {
	if len(m.XMLs) >= maxXMLsPerMail {
		return
	}
	data, err := decodeBody(h, body)
	if err != nil || len(data) == 0 || len(data) > maxXMLBytes {
		return
	}
	m.XMLs = append(m.XMLs, Attachment{Name: name, Data: data})
}

// ExtractZipXMLs zip arşivindeki .xml dosyalarını (en çok max adet, her biri ≤5 MB) çıkarır; bozuk arşivde boş döner.
func ExtractZipXMLs(data []byte, max int) []Attachment {
	if max <= 0 || len(data) == 0 || len(data) > maxAttachmentBytes {
		return nil
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil
	}
	var out []Attachment
	for _, f := range zr.File {
		if len(out) >= max {
			break
		}
		if !strings.HasSuffix(strings.ToLower(f.Name), ".xml") || f.UncompressedSize64 > maxXMLBytes {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		b, err := io.ReadAll(io.LimitReader(rc, maxXMLBytes))
		rc.Close()
		if err == nil && len(b) > 0 {
			out = append(out, Attachment{Name: path.Base(f.Name), Data: b})
		}
	}
	return out
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// ExtractZipPDFs zip arşivindeki .pdf dosyalarını (en çok max adet, her biri ≤20 MB) çıkarır; bozuk arşivde boş döner.
func ExtractZipPDFs(data []byte, max int) []Attachment {
	if max <= 0 || len(data) == 0 || len(data) > maxAttachmentBytes {
		return nil
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil
	}
	var out []Attachment
	for _, f := range zr.File {
		if len(out) >= max {
			break
		}
		if !strings.HasSuffix(strings.ToLower(f.Name), ".pdf") || f.UncompressedSize64 > maxAttachmentBytes {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		b, err := io.ReadAll(io.LimitReader(rc, maxAttachmentBytes))
		rc.Close()
		if err == nil && len(b) > 0 {
			out = append(out, Attachment{Name: path.Base(f.Name), Data: b})
		}
	}
	return out
}
