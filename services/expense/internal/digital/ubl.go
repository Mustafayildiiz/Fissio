package digital

import (
	"bytes"
	"encoding/xml"
	"errors"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/text/encoding/htmlindex"
)

// UBL-TR e-Fatura / e-Arşiv XML ayrıştırıcı (yalnız `Invoice` kökü). Namespace önekinden bağımsızdır (yerel ad eşleşmesi).
// Güvenlik: DOCTYPE/DTD reddedilir (varlık genişletme yok), derinlik/düğüm/boyut sınırı vardır, panikler yakalanır.

const (
	maxXMLBytes     = 5 << 20
	maxXMLsPerMail  = 5
	maxXMLDepth     = 40
	maxXMLNodes     = 50000
	maxInvoiceLines = 500
	// ublRoundingToleranceCents: PayableAmount ile kalem toplamı arasındaki bu kadar (0,05 TL altı) fark kuruş
	// yuvarlamasıdır; ayrı "KDV" kalemi üretmez.
	ublRoundingToleranceCents = 5
)

var (
	ErrNotUBL              = errors.New("not a ubl invoice")
	ErrUnsupportedCurrency = errors.New("unsupported invoice currency")
	ErrInvoiceNoAmount     = errors.New("invoice has no payable amount")
)

// InvoiceItem fatura satırı; tutar KDV'siz satır toplamıdır (kuruş).
type InvoiceItem struct {
	Name        string
	AmountCents int64
}

// Invoice UBL-TR faturasından çıkan yapılandırılmış fiş verisi.
type Invoice struct {
	ID          string // fatura numarası (cbc:ID)
	UUID        string // ETTN (cbc:UUID)
	IssueDate   string // YYYY-MM-DD ("" = okunamadı)
	Merchant    string
	AmountCents int64 // ödenecek tutar
	Currency    string
	OrderID     string // OrderReference/ID (ham)
	Items       []InvoiceItem
}

type xnode struct {
	name string
	text string
	kids []*xnode
}

func (n *xnode) child(name string) *xnode {
	if n == nil {
		return nil
	}
	for _, k := range n.kids {
		if k.name == name {
			return k
		}
	}
	return nil
}

func (n *xnode) children(name string) []*xnode {
	if n == nil {
		return nil
	}
	var out []*xnode
	for _, k := range n.kids {
		if k.name == name {
			out = append(out, k)
		}
	}
	return out
}

func (n *xnode) path(names ...string) *xnode {
	cur := n
	for _, nm := range names {
		cur = cur.child(nm)
		if cur == nil {
			return nil
		}
	}
	return cur
}

func (n *xnode) val() string {
	if n == nil {
		return ""
	}
	return strings.TrimSpace(n.text)
}

func parseXMLTree(data []byte) (*xnode, error) {
	d := xml.NewDecoder(bytes.NewReader(data))
	d.Strict = true
	d.CharsetReader = func(label string, in io.Reader) (io.Reader, error) {
		enc, err := htmlindex.Get(label)
		if err != nil {
			return nil, err
		}
		return enc.NewDecoder().Reader(in), nil
	}
	var root *xnode
	var stack []*xnode
	nodes := 0
	for {
		tok, err := d.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		switch t := tok.(type) {
		case xml.Directive:
			return nil, errors.New("xml directive not allowed")
		case xml.StartElement:
			nodes++
			if nodes > maxXMLNodes || len(stack) >= maxXMLDepth {
				return nil, errors.New("xml too complex")
			}
			n := &xnode{name: t.Name.Local}
			if len(stack) > 0 {
				p := stack[len(stack)-1]
				p.kids = append(p.kids, n)
			} else if root == nil {
				root = n
			}
			stack = append(stack, n)
		case xml.EndElement:
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
			}
		case xml.CharData:
			if len(stack) > 0 {
				cur := stack[len(stack)-1]
				if len(cur.text) < 4096 {
					cur.text += string(t)
				}
			}
		}
	}
	if root == nil {
		return nil, ErrNotUBL
	}
	return root, nil
}

var decimalRe = regexp.MustCompile(`^-?\d+(?:\.\d+)?$`)

// parseCents "1234.56" (UBL ondalık noktası) → kuruş.
func parseCents(s string) (int64, bool) {
	s = strings.TrimSpace(s)
	if !decimalRe.MatchString(s) {
		return 0, false
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
		return 0, false
	}
	return int64(math.Round(f * 100)), true
}

func formatQty(q float64) string {
	return strconv.FormatFloat(q, 'f', -1, 64)
}

// ParseUBL UBL-TR `Invoice` XML'ini yapılandırılmış veriye çevirir.
func ParseUBL(data []byte) (inv *Invoice, err error) {
	defer func() {
		if r := recover(); r != nil {
			inv, err = nil, ErrNotUBL
		}
	}()
	if len(data) == 0 || len(data) > maxXMLBytes {
		return nil, ErrNotUBL
	}
	root, err := parseXMLTree(data)
	if err != nil {
		return nil, ErrNotUBL
	}
	if root.name != "Invoice" {
		return nil, ErrNotUBL
	}
	inv = &Invoice{
		ID:       root.child("ID").val(),
		UUID:     root.child("UUID").val(),
		Currency: strings.ToUpper(root.child("DocumentCurrencyCode").val()),
		OrderID:  root.path("OrderReference", "ID").val(),
	}
	if inv.Currency == "" {
		inv.Currency = "TRY"
	}
	if inv.Currency != "TRY" && inv.Currency != "TRL" {
		return nil, ErrUnsupportedCurrency
	}
	if d := root.child("IssueDate").val(); d != "" {
		if t, e := time.Parse("2006-01-02", d); e == nil {
			inv.IssueDate = t.Format("2006-01-02")
		}
	}

	party := root.path("AccountingSupplierParty", "Party")
	inv.Merchant = party.path("PartyName", "Name").val()
	if inv.Merchant == "" {
		inv.Merchant = party.path("PartyLegalEntity", "RegistrationName").val()
	}
	if inv.Merchant == "" {
		p := party.child("Person")
		inv.Merchant = strings.TrimSpace(p.child("FirstName").val() + " " + p.child("FamilyName").val())
	}

	mt := root.child("LegalMonetaryTotal")
	for _, k := range []string{"PayableAmount", "TaxInclusiveAmount"} {
		if c, ok := parseCents(mt.child(k).val()); ok && c > 0 {
			inv.AmountCents = c
			break
		}
	}
	if inv.AmountCents <= 0 {
		return nil, ErrInvoiceNoAmount
	}

	var sum int64
	for i, line := range root.children("InvoiceLine") {
		if i >= maxInvoiceLines {
			break
		}
		name := line.path("Item", "Name").val()
		if name == "" {
			name = line.path("Item", "Description").val()
		}
		cents, ok := parseCents(line.child("LineExtensionAmount").val())
		if name == "" || !ok || cents < 0 {
			continue
		}
		if q, err := strconv.ParseFloat(line.child("InvoicedQuantity").val(), 64); err == nil && q > 1 {
			name = formatQty(q) + " x " + name
		}
		inv.Items = append(inv.Items, InvoiceItem{Name: name, AmountCents: cents})
		sum += cents
	}
	// Satır tutarları KDV'sizdir: ödenecek tutarla aradaki fark (KDV; belge düzeyinde ücret varsa o da dahil) ayrı kalem olur.
	// Fark kuruş yuvarlaması düzeyindeyse ya da negatifse (belge indirimi KDV'den büyük) satır eklenmez.
	if len(inv.Items) > 0 {
		if diff := inv.AmountCents - sum; diff >= ublRoundingToleranceCents {
			inv.Items = append(inv.Items, InvoiceItem{Name: "KDV", AmountCents: diff})
		}
	}
	return inv, nil
}
