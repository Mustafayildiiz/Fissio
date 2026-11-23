package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/mail"
	"strconv"
	"strings"
	"time"

	"fissio/expense/internal/digital"
	"fissio/expense/internal/receiptparse"
)

// expenseFromEmail e-posta metnini ayrıştırıp kayda hazır expenseInput'a çevirir. ok=false: kaydedilemez (reason).
func (h *handler) expenseFromEmail(userID int64, text, source string, msg *digital.Message) (expenseInput, bool, string, error) {
	cats, err := h.loadCategories()
	if err != nil {
		return expenseInput{}, false, "", err
	}
	rules, err := loadRules(h.db, userID)
	if err != nil {
		return expenseInput{}, false, "", err
	}
	if len(text) > 20000 {
		text = text[:20000]
	}
	parsed := receiptparse.ParseWith(text, cats, time.Now(), receiptparse.ParseOptions{Rules: rules})
	if parsed.Amount == nil || *parsed.Amount <= 0 {
		return expenseInput{}, false, "no_amount", nil
	}
	// Platform sipariş özetleri (Yemeksepeti, Getir, Trendyol Yemek…): HTML tablosundaki ad/adet/satır tutarı genel
	// metin ayrıştırmasından daha doğruysa (kalem bulunamadı ya da toplam tutmuyor) tablo kalemleri kullanılır.
	if source == digital.SourceHTML {
		if tbl := digital.HTMLTableItems(msg.HTML); preferTableItems(parsed.Items, tbl, *parsed.Amount) {
			items := make([]receiptparse.Item, 0, len(tbl))
			for _, it := range tbl {
				items = append(items, receiptparse.Item{Name: it.DisplayName(), Amount: float64(it.AmountCents) / 100})
			}
			parsed.Items = receiptparse.CategorizeStructured(parsed.Merchant, *parsed.Amount, items, parsed.Date, cats,
				receiptparse.ParseOptions{Rules: rules}).Items
		}
	}
	date := time.Now().UTC().Format(dateLayout)
	switch {
	case parsed.Date != nil:
		date = *parsed.Date
	case !msg.Date.IsZero():
		date = msg.Date.UTC().Format(dateLayout)
	}
	catID := parsed.CategoryID
	if catID == 0 {
		for _, c := range cats {
			if c.Name == "Diğer" {
				catID = c.ID
			}
		}
	}
	// Fiyatsız ürün listesi ("Ürün - (Adet: 1)") + yalnız toplam: kalem fiyatı uydurulmaz; kalem bulunamadıysa net
	// toplam tek kaleme yazılır. Tutar bu adımdan etkilenmez.
	if len(parsed.Items) == 0 {
		if lines := digital.ProductLinesWithQty(text); len(lines) > 0 {
			parsed.Items = []receiptparse.Item{{Name: singleItemName(lines), Amount: *parsed.Amount}}
		}
	}
	// Satıcı: etiketli satır > cümle/sipariş no olmayan ayrıştırıcı sonucu > özgün (iletilen) gönderici > gönderen adı >
	// gönderen domaini (bkz. digital.ChooseMerchant).
	merchant := digital.ChooseMerchant(parsed.Merchant, text, msg)
	if merchant == "" {
		merchant = "E-posta fişi"
	}
	if r := []rune(merchant); len(r) > 60 {
		merchant = string(r[:60])
	}
	engine := "email"
	if source == digital.SourcePDF {
		engine = "pdf"
	}
	docNo := digital.ExtractDocumentNo(text)
	orderID := digital.ExtractOrderID(text)
	in := expenseInput{
		Merchant:   merchant,
		Amount:     *parsed.Amount,
		Date:       date,
		CategoryID: catID,
		Note:       emailNote(msg.Subject),
		Items:      itemsOrEmpty(parsed.Items),
		ClientUID:  mailClientUID(userID, text),
		OcrEngine:  &engine,
	}
	if docNo != "" {
		in.DocumentNo = &docNo
	}
	if orderID != "" {
		in.OrderID = &orderID
	}
	if _, msg := in.validate(); msg != "" {
		return expenseInput{}, false, "invalid:" + msg, nil
	}
	return in, true, "", nil
}

// singleItemName fiyatsız ürün satırlarından tek kalem adı: tek ürünse "N x Ad" (N>1), çoksa adlar " + " ile (≤80 rune).
func singleItemName(lines []digital.ProductLine) string {
	var name string
	if len(lines) == 1 {
		name = lines[0].Name
		if lines[0].Qty > 1 {
			name = strconv.Itoa(lines[0].Qty) + " x " + name
		}
	} else {
		parts := make([]string, 0, len(lines))
		for _, l := range lines {
			parts = append(parts, l.Name)
		}
		name = strings.Join(parts, " + ")
	}
	if r := []rune(name); len(r) > 80 {
		name = string(r[:80])
	}
	return name
}

func itemsOrEmpty(items []expenseItem) []expenseItem {
	if items == nil {
		return []expenseItem{}
	}
	return items
}

func emailNote(subject string) string {
	s := strings.TrimSpace(subject)
	if s == "" {
		return ""
	}
	r := []rune("E-posta: " + s)
	if len(r) > 200 {
		r = r[:200]
	}
	return string(r)
}

func displayName(from string) string {
	if a, err := mail.ParseAddress(from); err == nil && strings.TrimSpace(a.Name) != "" {
		return strings.TrimSpace(a.Name)
	}
	return ""
}

// mailClientUID: aynı mail iki kez iletilse bile (yeni Message-ID) aynı kayda çözülsün diye ÖNSÖZÜ ATILMIŞ gövde metninden
// türetilir (boşluk/harf farkından bağımsız).
func mailClientUID(userID int64, text string) string {
	canon := strings.Join(strings.Fields(receiptparse.FoldTR(text)), " ")
	sum := sha256.Sum256([]byte(strconv.FormatInt(userID, 10) + "|" + canon))
	return "mail-" + hex.EncodeToString(sum[:8])
}

// ---- UBL-TR XML kaynağı -------------------------------------------------------------------------------------------

// firstInvoice mailin eklerindeki ilk geçerli UBL-TR faturasını verir (yoksa nil → PDF/HTML/metin kaynaklarına düşülür).
func firstInvoice(msg *digital.Message) *digital.Invoice {
	for _, a := range msg.XMLs {
		if inv, err := digital.ParseUBL(a.Data); err == nil {
			return inv
		}
	}
	return nil
}

// expenseFromInvoice UBL-TR faturasını kayda hazır expenseInput'a çevirir. Metin ayrıştırması yapılmaz: satıcı, tarih,
// ödenecek tutar ve kalemler yapılandırılmış gelir; kategori motoru yalnızca sınıflandırır.
func (h *handler) expenseFromInvoice(userID int64, inv *digital.Invoice, msg *digital.Message) (expenseInput, bool, string, error) {
	cats, err := h.loadCategories()
	if err != nil {
		return expenseInput{}, false, "", err
	}
	rules, err := loadRules(h.db, userID)
	if err != nil {
		return expenseInput{}, false, "", err
	}
	date := time.Now().UTC().Format(dateLayout)
	switch {
	case inv.IssueDate != "":
		date = inv.IssueDate
	case !msg.Date.IsZero():
		date = msg.Date.UTC().Format(dateLayout)
	}
	merchant := strings.TrimSpace(inv.Merchant)
	if merchant == "" {
		merchant = displayName(msg.From)
	}
	if merchant == "" {
		merchant = "E-posta fişi"
	}
	items := make([]receiptparse.Item, 0, len(inv.Items))
	for _, it := range inv.Items {
		items = append(items, receiptparse.Item{Name: it.Name, Amount: float64(it.AmountCents) / 100})
	}
	amount := float64(inv.AmountCents) / 100
	parsed := receiptparse.CategorizeStructured(merchant, amount, items, &date, cats, receiptparse.ParseOptions{Rules: rules})
	catID := parsed.CategoryID
	if catID == 0 {
		for _, c := range cats {
			if c.Name == "Diğer" {
				catID = c.ID
			}
		}
	}
	engine := "xml"
	key := inv.UUID + "|" + inv.ID + "|" + merchant + "|" + strconv.FormatInt(inv.AmountCents, 10)
	sum := sha256.Sum256([]byte(strconv.FormatInt(userID, 10) + "|" + key))
	in := expenseInput{
		Merchant:   merchant,
		Amount:     amount,
		Date:       date,
		CategoryID: catID,
		Note:       emailNote(msg.Subject),
		Items:      itemsOrEmpty(parsed.Items),
		ClientUID:  "mail-" + hex.EncodeToString(sum[:8]),
		OcrEngine:  &engine,
	}
	if d := digital.NormalizeDocumentNo(inv.UUID); d != "" {
		in.DocumentNo = &d
	}
	if o := digital.NormalizeOrderID(inv.OrderID); o != "" {
		in.OrderID = &o
	}
	if _, msg := in.validate(); msg != "" {
		return expenseInput{}, false, "invalid:" + msg, nil
	}
	return in, true, "", nil
}

// preferTableItems HTML tablo kalemlerinin genel metin ayrıştırıcının kalemlerinden daha iyi olup olmadığına karar verir:
// tablo toplamı fiş tutarıyla uyuşuyorsa (≤0,05 TL), ayrıştırıcı kalem bulamadıysa ya da tablo toplamı tutara daha
// yakınsa true. İndirim gibi tutarı tablodan saptıran durumlarda genel ayrıştırıcının sonucu korunur.
func preferTableItems(parsed []receiptparse.Item, table []digital.TableItem, amount float64) bool {
	if len(table) == 0 {
		return false
	}
	if len(parsed) == 0 {
		return true
	}
	var ps, ts float64
	for _, it := range parsed {
		ps += it.Amount
	}
	for _, it := range table {
		ts += float64(it.AmountCents) / 100
	}
	abs := func(v float64) float64 {
		if v < 0 {
			return -v
		}
		return v
	}
	dp, dt := abs(ps-amount), abs(ts-amount)
	if dt <= 0.05 {
		// Yapılandırılmış tablo fiş tutarıyla uyuşuyor: ad/adet/satır tutarı en güvenilir kaynaktır (genel ayrıştırıcı
		// birim fiyat sütunlarını kalem adına katabilir: "Ayran 1 15,00 TL").
		return true
	}
	return dp > 0.05 && dt < dp
}
