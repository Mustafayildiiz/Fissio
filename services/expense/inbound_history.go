package main

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"

	"fissio/expense/internal/digital"
	"fissio/expense/internal/receiptparse"
)

// E-posta aktarım geçmişi: webhook'a gelen her mailin akıbeti (kaydedildi / atlandı / hata) kullanıcı başına son
// inboundHistoryKept satır olarak tutulur. Mail gövdesi ve ekleri SAKLANMAZ; yalnızca gönderici, konu, durum, neden ve
// (varsa) ilgili fiş kimliği.

const (
	historySaved   = "saved"
	historyIgnored = "ignored"
	historyFailed  = "failed"

	inboundHistoryKept    = 50
	inboundHistoryDefault = 20
	historyFieldRunes     = 200
)

func cleanHistoryField(s string) string {
	s = strings.Map(func(r rune) rune {
		if r == 0 || unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > historyFieldRunes {
		s = string(r[:historyFieldRunes])
	}
	return s
}

// recordInboundHistory geçmişe satır ekler ve kullanıcı başına eski satırları kırpar. Hata yutulur (loglanır): geçmiş
// yazımı webhook sonucunu asla değiştirmemeli.
func (h *handler) recordInboundHistory(userID int64, from, subject, status, reason string, expenseID int64) {
	var exp any
	if expenseID > 0 {
		exp = expenseID
	}
	if _, err := h.db.Exec(
		`INSERT INTO expense.inbound_history (user_id, from_addr, subject, status, reason, expense_id) VALUES ($1, $2, $3, $4, $5, $6)`,
		userID, cleanHistoryField(from), cleanHistoryField(subject), status, cleanHistoryField(reason), exp); err != nil {
		log.Printf("inbound: history insert failed for user %d: %v", userID, err)
		return
	}
	if _, err := h.db.Exec(
		`DELETE FROM expense.inbound_history WHERE user_id = $1 AND id NOT IN
		 (SELECT id FROM expense.inbound_history WHERE user_id = $1 ORDER BY received_at DESC, id DESC LIMIT $2)`,
		userID, inboundHistoryKept); err != nil {
		log.Printf("inbound: history trim failed for user %d: %v", userID, err)
	}
}

type inboundHistoryItem struct {
	ID         int64  `json:"id"`
	Source     string `json:"source"`
	From       string `json:"from"`
	Subject    string `json:"subject"`
	ReceivedAt string `json:"received_at"`
	Status     string `json:"status"`
	Reason     string `json:"reason,omitempty"`
	ExpenseID  *int64 `json:"expense_id,omitempty"`
}

// GET /inbound-address/history?limit=: son aktarılan e-postalar (yeniden eskiye). Özellik kapalıysa boş liste.
func (h *handler) getInboundHistory(c *gin.Context) {
	items := []inboundHistoryItem{}
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, gin.H{"enabled": false, "items": items})
		return
	}
	limit := inboundHistoryDefault
	if v, err := strconv.Atoi(c.Query("limit")); err == nil && v > 0 {
		limit = v
	}
	if limit > inboundHistoryKept {
		limit = inboundHistoryKept
	}
	rows, err := h.db.Query(
		`SELECT id, source, from_addr, subject, received_at, status, reason, expense_id
		   FROM expense.inbound_history WHERE user_id = $1 ORDER BY received_at DESC, id DESC LIMIT $2`,
		c.GetInt64("userID"), limit)
	if err != nil {
		serverError(c)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var it inboundHistoryItem
		var at time.Time
		var reason, from, subject *string
		var exp *int64
		if err := rows.Scan(&it.ID, &it.Source, &from, &subject, &at, &it.Status, &reason, &exp); err != nil {
			serverError(c)
			return
		}
		if from != nil {
			it.From = *from
		}
		if subject != nil {
			it.Subject = *subject
		}
		if reason != nil {
			it.Reason = *reason
		}
		it.ExpenseID = exp
		it.ReceivedAt = formatUpdatedAt(at)
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, gin.H{"enabled": true, "items": items})
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
