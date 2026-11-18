package main

import (
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"
)

// Tekrarlayan giderler ("Her ay tekrarlanir"): isaret fisin kendisinde (recurring_day, recurring_remind) tutulur.
//
// Cift sayim onlemi: ayni gider her ay yeni bir fis olarak girilir (Ocak ve Subat elektrik faturasi). Projeksiyon
// fis basina degil SERI basina hesaplanir. Seri anahtari = kategori + normalize edilmis isletme adi; serinin
// guncel hali o anahtardaki EN SON fistir (tarih, sonra id). En son fis "tekrarlanir" isaretliyse seri aktiftir
// ve tutari/odeme gunu o fisten gelir; en son fis isaretsizse seri bitmis sayilir (kullanici isareti kaldirdi).
// Mobildeki ayni hesap: lib/recurring.dart.

type recurringRow struct {
	ID           int64
	ProfileID    int64
	Merchant     string
	CategoryID   int
	CategoryName string
	Amount       float64
	Date         time.Time
	Day          int // 0 = tekrarlamaz
	Remind       bool
}

type recurringOut struct {
	SeriesKey     string  `json:"series_key"`
	ProfileID     int64   `json:"profile_id"`
	Merchant      string  `json:"merchant"`
	CategoryID    int     `json:"category_id"`
	CategoryName  string  `json:"category_name"`
	Amount        float64 `json:"amount"`
	Day           int     `json:"day"`
	Remind        bool    `json:"remind"`
	LastExpenseID int64   `json:"last_expense_id"`
	LastDate      string  `json:"last_date"`
	NextDue       string  `json:"next_due"`
}

// seriesKey: "<kategori>|<kucuk harf, Turkce katlanmis, harf/rakam jetonlari>"; isletme adi bossa yalnizca kategori.
func seriesKey(merchant string, categoryID int) string {
	toks := strings.FieldsFunc(foldTR(merchant), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	return strconv.Itoa(categoryID) + "|" + strings.Join(toks, " ")
}

func daysInMonth(y int, m time.Month) int {
	return time.Date(y, m+1, 0, 0, 0, 0, 0, time.UTC).Day()
}

// clampedDate ayin gun sayisini asan gunu (31 Subat gibi) ayin son gunune ceker.
func clampedDate(y int, m time.Month, day int) time.Time {
	// time.Date ay tasmasini normalize eder; once ay tabanini sabitle.
	base := time.Date(y, m, 1, 0, 0, 0, 0, time.UTC)
	y, m = base.Year(), base.Month()
	if n := daysInMonth(y, m); day > n {
		day = n
	}
	return time.Date(y, m, day, 0, 0, 0, 0, time.UTC)
}

// nextDue serinin bir sonraki odeme tarihi: bu ayin odeme gunu (henuz gecmediyse ve bu ay icin bir fis
// girilmediyse), aksi halde gelecek ayin odeme gunu.
func nextDue(day int, last, today time.Time) time.Time {
	y, m := today.Year(), today.Month()
	due := clampedDate(y, m, day)
	paidThisMonth := last.Year() == y && last.Month() == m
	if paidThisMonth || due.Before(today) {
		due = clampedDate(y, m+1, day)
	}
	return due
}

// buildRecurring satirlardan aktif serileri cikarir (profil basina ayri seri). today UTC gece yarisina indirilmis olmali.
func buildRecurring(rows []recurringRow, today time.Time) ([]recurringOut, float64) {
	latest := map[string]recurringRow{}
	for _, r := range rows {
		k := strconv.FormatInt(r.ProfileID, 10) + "#" + seriesKey(r.Merchant, r.CategoryID)
		cur, ok := latest[k]
		if !ok || r.Date.After(cur.Date) || (r.Date.Equal(cur.Date) && r.ID > cur.ID) {
			latest[k] = r
		}
	}
	out := []recurringOut{}
	total := 0.0
	for _, r := range latest {
		if r.Day == 0 {
			continue
		}
		due := nextDue(r.Day, r.Date, today)
		out = append(out, recurringOut{
			SeriesKey: seriesKey(r.Merchant, r.CategoryID), ProfileID: r.ProfileID, Merchant: r.Merchant,
			CategoryID: r.CategoryID, CategoryName: r.CategoryName, Amount: r.Amount, Day: r.Day, Remind: r.Remind,
			LastExpenseID: r.ID, LastDate: r.Date.Format(dateLayout), NextDue: due.Format(dateLayout),
		})
		total += r.Amount
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].NextDue != out[j].NextDue {
			return out[i].NextDue < out[j].NextDue
		}
		return out[i].SeriesKey < out[j].SeriesKey
	})
	return out, float64(int64(total*100+0.5)) / 100
}

// listRecurring: aktif tekrarlayan giderler ve "Aylik Sabit Gider Projeksiyonu". profile_id verilirse yalnizca o
// profil (sahiplik dogrulanir), verilmezse hesabin tum profilleri.
func (h *handler) listRecurring(c *gin.Context) {
	userID := c.GetInt64("userID")
	q := `SELECT e.id, e.profile_id, e.merchant, e.category_id, c.name, e.amount, e.spent_at, COALESCE(e.recurring_day, 0), e.recurring_remind
		FROM expense.expenses e JOIN expense.categories c ON c.id = e.category_id
		WHERE e.user_id = $1
		  AND EXISTS (SELECT 1 FROM expense.expenses r WHERE r.user_id = e.user_id AND r.profile_id = e.profile_id
		              AND r.category_id = e.category_id AND r.recurring_day IS NOT NULL)`
	args := []any{userID}
	if v := c.Query("profile_id"); v != "" {
		pid, ok := h.profileFilter(c, v)
		if !ok {
			return
		}
		args = append(args, pid)
		q += ` AND e.profile_id = $2`
	}
	rows, err := h.db.Query(q, args...)
	if err != nil {
		serverError(c)
		return
	}
	defer rows.Close()
	var all []recurringRow
	for rows.Next() {
		var r recurringRow
		if err := rows.Scan(&r.ID, &r.ProfileID, &r.Merchant, &r.CategoryID, &r.CategoryName, &r.Amount, &r.Date, &r.Day, &r.Remind); err != nil {
			serverError(c)
			return
		}
		all = append(all, r)
	}
	if rows.Err() != nil {
		serverError(c)
		return
	}
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	items, total := buildRecurring(all, today)
	c.JSON(http.StatusOK, gin.H{"monthly_total": total, "count": len(items), "items": items})
}
