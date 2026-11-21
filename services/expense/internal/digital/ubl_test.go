package digital

import (
	"errors"
	"strings"
	"testing"
)

const ublSample = `<?xml version="1.0" encoding="UTF-8"?>
<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
  xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
  xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
  <cbc:UBLVersionID>2.1</cbc:UBLVersionID>
  <cbc:ID>ABL2026000001234</cbc:ID>
  <cbc:UUID>F47AC10B-58CC-4372-A567-0E02B2C3D479</cbc:UUID>
  <cbc:IssueDate>2026-11-14</cbc:IssueDate>
  <cbc:DocumentCurrencyCode>TRY</cbc:DocumentCurrencyCode>
  <cac:OrderReference><cbc:ID>sip-12345</cbc:ID></cac:OrderReference>
  <cac:AccountingSupplierParty>
    <cac:Party>
      <cac:PartyName><cbc:Name>ABLUKA Teknoloji A.Ş.</cbc:Name></cac:PartyName>
    </cac:Party>
  </cac:AccountingSupplierParty>
  <cac:TaxTotal><cbc:TaxAmount currencyID="TRY">36.00</cbc:TaxAmount></cac:TaxTotal>
  <cac:LegalMonetaryTotal>
    <cbc:LineExtensionAmount currencyID="TRY">180.00</cbc:LineExtensionAmount>
    <cbc:PayableAmount currencyID="TRY">216.00</cbc:PayableAmount>
  </cac:LegalMonetaryTotal>
  <cac:InvoiceLine>
    <cbc:ID>1</cbc:ID>
    <cbc:InvoicedQuantity unitCode="C62">2</cbc:InvoicedQuantity>
    <cbc:LineExtensionAmount currencyID="TRY">100.00</cbc:LineExtensionAmount>
    <cac:Item><cbc:Name>Bulut Depolama</cbc:Name></cac:Item>
  </cac:InvoiceLine>
  <cac:InvoiceLine>
    <cbc:ID>2</cbc:ID>
    <cbc:InvoicedQuantity unitCode="C62">1</cbc:InvoicedQuantity>
    <cbc:LineExtensionAmount currencyID="TRY">80.00</cbc:LineExtensionAmount>
    <cac:Item><cbc:Name>Destek Paketi</cbc:Name></cac:Item>
  </cac:InvoiceLine>
</Invoice>`

func TestParseUBLFull(t *testing.T) {
	inv, err := ParseUBL([]byte(ublSample))
	if err != nil {
		t.Fatal(err)
	}
	if inv.ID != "ABL2026000001234" || inv.UUID != "F47AC10B-58CC-4372-A567-0E02B2C3D479" || inv.IssueDate != "2026-11-14" {
		t.Fatalf("header: %+v", inv)
	}
	if inv.Merchant != "ABLUKA Teknoloji A.Ş." || inv.AmountCents != 21600 || inv.OrderID != "sip-12345" {
		t.Fatalf("fields: %+v", inv)
	}
	want := []InvoiceItem{{"2 x Bulut Depolama", 10000}, {"Destek Paketi", 8000}, {"KDV", 3600}}
	if len(inv.Items) != len(want) {
		t.Fatalf("items: %+v", inv.Items)
	}
	for i, w := range want {
		if inv.Items[i] != w {
			t.Fatalf("item %d = %+v, want %+v", i, inv.Items[i], w)
		}
	}
	if NormalizeDocumentNo(inv.UUID) != "f47ac10b-58cc-4372-a567-0e02b2c3d479" {
		t.Fatal("ettn must normalize to lower case")
	}
}

func TestParseUBLOtherPrefixesAndPersonSupplier(t *testing.T) {
	x := `<inv:Invoice xmlns:inv="urn:x" xmlns:a="urn:a" xmlns:b="urn:b">
	  <b:ID>X1</b:ID><b:IssueDate>2026-01-02</b:IssueDate>
	  <a:AccountingSupplierParty><a:Party><a:Person><b:FirstName>Ayşe</b:FirstName><b:FamilyName>Yılmaz</b:FamilyName></a:Person></a:Party></a:AccountingSupplierParty>
	  <a:LegalMonetaryTotal><b:TaxInclusiveAmount>50.00</b:TaxInclusiveAmount></a:LegalMonetaryTotal>
	  <a:InvoiceLine><b:LineExtensionAmount>50.00</b:LineExtensionAmount><a:Item><b:Name>Danışmanlık</b:Name></a:Item></a:InvoiceLine>
	</inv:Invoice>`
	inv, err := ParseUBL([]byte(x))
	if err != nil {
		t.Fatal(err)
	}
	if inv.Merchant != "Ayşe Yılmaz" || inv.AmountCents != 5000 || len(inv.Items) != 1 {
		t.Fatalf("%+v", inv)
	}
}

func TestParseUBLRoundingDifferenceAddsNoVATLine(t *testing.T) {
	mk := func(payable string) string {
		return `<Invoice><IssueDate>2026-01-02</IssueDate>
		<LegalMonetaryTotal><PayableAmount>` + payable + `</PayableAmount></LegalMonetaryTotal>
		<InvoiceLine><LineExtensionAmount>100.00</LineExtensionAmount><Item><Name>Ürün</Name></Item></InvoiceLine></Invoice>`
	}
	inv, err := ParseUBL([]byte(mk("100.03")))
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Items) != 1 {
		t.Fatalf("0,03 TL yuvarlama için KDV satırı olmamalı: %+v", inv.Items)
	}
	inv, err = ParseUBL([]byte(mk("100.05")))
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Items) != 2 || inv.Items[1].Name != "KDV" || inv.Items[1].AmountCents != 5 {
		t.Fatalf("0,05 TL ve üzeri fark KDV satırı olmalı: %+v", inv.Items)
	}
	// Belge indirimi KDV'den büyük: payable < kalem toplamı → satır eklenmez.
	inv, err = ParseUBL([]byte(mk("90.00")))
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Items) != 1 {
		t.Fatalf("negatif fark satır üretmemeli: %+v", inv.Items)
	}
}

func TestParseUBLRejects(t *testing.T) {
	cases := map[string]struct {
		xml string
		err error
	}{
		"not xml":      {"hello", ErrNotUBL},
		"other root":   {`<CreditNote><ID>1</ID></CreditNote>`, ErrNotUBL},
		"broken":       {`<Invoice><ID>1</Invoice>`, ErrNotUBL},
		"no amount":    {`<Invoice><ID>1</ID></Invoice>`, ErrInvoiceNoAmount},
		"foreign cur":  {`<Invoice><DocumentCurrencyCode>USD</DocumentCurrencyCode><LegalMonetaryTotal><PayableAmount>5.00</PayableAmount></LegalMonetaryTotal></Invoice>`, ErrUnsupportedCurrency},
		"doctype/xxe":  {`<?xml version="1.0"?><!DOCTYPE Invoice [<!ENTITY x SYSTEM "file:///etc/passwd">]><Invoice><ID>&x;</ID></Invoice>`, ErrNotUBL},
		"empty":        {"", ErrNotUBL},
		"deep nesting": {strings.Repeat("<a>", 200) + strings.Repeat("</a>", 200), ErrNotUBL},
	}
	for name, c := range cases {
		if _, err := ParseUBL([]byte(c.xml)); !errors.Is(err, c.err) {
			t.Errorf("%s: err = %v, want %v", name, err, c.err)
		}
	}
}
