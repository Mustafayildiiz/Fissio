package main

import (
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"
)

const maxBulkExpenses = 500

type bulkInput struct {
	// ProfileID varsayilan profil; her fis kendi profile_id'sini tasiyabilir (coklu profilli iceri aktarma).
	ProfileID int64          `json:"profile_id"`
	Expenses  []expenseInput `json:"expenses"`
}

type bulkResult struct {
	Index     int    `json:"index"`
	ClientUID string `json:"client_uid"`
	Status    string `json:"status"` // created | skipped | error
	ID        int64  `json:"id,omitempty"`
	Error     string `json:"error,omitempty"`
}

// bulkExpenses cevrimdisi kuyruk bosaltma ve yedekten iceri aktarma icin toplu, idempotent kayit:
// her fis client_uid ile tekildir; zaten var olan "skipped" olur. Gecersiz fisler "error" olarak raporlanir
// ve digerlerini engellemez. Tum gecerli fisler tek islemde yazilir.
func (h *handler) bulkExpenses(c *gin.Context) {
	var in bulkInput
	if err := c.ShouldBindJSON(&in); err != nil {
		badRequest(c, "invalid request body")
		return
	}
	if len(in.Expenses) == 0 || len(in.Expenses) > maxBulkExpenses {
		badRequest(c, "expenses must contain 1-500 items")
		return
	}
	userID := c.GetInt64("userID")
	cats, err := h.loadCategories()
	if err != nil {
		serverError(c)
		return
	}
	// Profil sahipligi bir kez cozulur (profil basina tek sorgu).
	profiles := map[int64]int64{}
	resolve := func(id int64) (int64, bool, error) {
		if v, ok := profiles[id]; ok {
			return v, v != 0, nil
		}
		pid, found, err := h.resolveProfile(userID, id)
		if err != nil {
			return 0, false, err
		}
		if !found {
			pid = 0
		}
		profiles[id] = pid
		return pid, found, nil
	}

	results := make([]bulkResult, len(in.Expenses))
	tx, err := h.db.Begin()
	if err != nil {
		serverError(c)
		return
	}
	defer tx.Rollback()

	created, skipped, failed := 0, 0, 0
	for i := range in.Expenses {
		e := &in.Expenses[i]
		res := bulkResult{Index: i, ClientUID: e.ClientUID}
		fail := func(msg string) {
			res.Status, res.Error = "error", msg
			failed++
			results[i] = res
		}
		if e.ClientUID == "" {
			fail("client_uid is required")
			continue
		}
		d, msg := e.validate()
		if msg != "" {
			fail(msg)
			continue
		}
		if !itemCategoriesValid(e.Items, cats) || !categoryKnown(e.CategoryID, cats) {
			fail("unknown category_id")
			continue
		}
		pidIn := e.ProfileID
		if pidIn == 0 {
			pidIn = in.ProfileID
		}
		pid, found, err := resolve(pidIn)
		if err != nil {
			serverError(c)
			return
		}
		if !found {
			fail("profile not found")
			continue
		}
		itemsJSON, _ := json.Marshal(itemsForStorage(e.Items))
		id, wasCreated, err := insertExpense(tx, userID, pid, e.ClientUID, *e, d, string(itemsJSON))
		if err != nil {
			serverError(c)
			return
		}
		res.ID = id
		if wasCreated {
			if err := saveRules(tx, userID, collectRuleUpdates(*e)); err != nil {
				serverError(c)
				return
			}
			res.Status = "created"
			created++
		} else {
			res.Status = "skipped"
			skipped++
		}
		results[i] = res
	}
	if err := tx.Commit(); err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, gin.H{"created": created, "skipped": skipped, "failed": failed, "results": results})
}

func categoryKnown(id int, cats []Category) bool {
	for _, c := range cats {
		if c.ID == id {
			return true
		}
	}
	return false
}
