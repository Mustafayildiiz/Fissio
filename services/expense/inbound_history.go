package main

import (
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"
)

// E-posta aktarım geçmişi: webhook'a gelen her mailin akıbeti (kaydedildi / atlandı / hata) kullanıcı başına son
// inboundHistoryKept satır olarak tutulur (PROFİL başına: her profilin kendi adresi ve geçmişi vardır). Mail gövdesi ve ekleri SAKLANMAZ; yalnızca gönderici, konu, durum, neden ve
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

// recordInboundHistory geçmişe satır ekler ve profil başına eski satırları kırpar. Hata yutulur (loglanır): geçmiş
// yazımı webhook sonucunu asla değiştirmemeli.
func (h *handler) recordInboundHistory(userID, profileID int64, from, subject, status, reason string, expenseID int64) {
	var exp any
	if expenseID > 0 {
		exp = expenseID
	}
	if _, err := h.db.Exec(
		`INSERT INTO expense.inbound_history (user_id, profile_id, from_addr, subject, status, reason, expense_id) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		userID, profileID, cleanHistoryField(from), cleanHistoryField(subject), status, cleanHistoryField(reason), exp); err != nil {
		log.Printf("inbound: history insert failed for user %d: %v", userID, err)
		return
	}
	if _, err := h.db.Exec(
		`DELETE FROM expense.inbound_history WHERE user_id = $1 AND profile_id = $2 AND id NOT IN
		 (SELECT id FROM expense.inbound_history WHERE user_id = $1 AND profile_id = $2 ORDER BY received_at DESC, id DESC LIMIT $3)`,
		userID, profileID, inboundHistoryKept); err != nil {
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

// GET /inbound-address/history?profile_uid=&limit=: profilin son aktarılan e-postaları (yeniden eskiye).
// Özellik kapalıysa boş liste.
func (h *handler) getInboundHistory(c *gin.Context) {
	items := []inboundHistoryItem{}
	if !h.inbound.enabled() {
		c.JSON(http.StatusOK, gin.H{"enabled": false, "items": items})
		return
	}
	pid, ok := h.inboundProfile(c, 0)
	if !ok {
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
		   FROM expense.inbound_history WHERE user_id = $1 AND profile_id = $2 ORDER BY received_at DESC, id DESC LIMIT $3`,
		c.GetInt64("userID"), pid, limit)
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
