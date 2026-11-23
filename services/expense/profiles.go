package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/lib/pq"

	"fissio/expense/internal/receiptparse"
)

// Profiller hesaba (user_id) aittir: User -> Profiles -> Receipts. Her sorgu user_id ile sinirlidir;
// baska hesabin profili/fisi 404 doner.
const (
	maxProfilesPerUser = 8
	defaultProfileName = "Kişisel"
)

// Profil hata kodlari (istemci Turkce mesaji koda gore secer).
const (
	codeProfileLimit         = "profile_limit"
	codeDuplicateProfileName = "duplicate_profile_name"
	codeProfileNotFound      = "profile_not_found"
)

var clientUIDRe = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,64}$`)

type profileOut struct {
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	ClientUID string    `json:"client_uid"`
	CreatedAt time.Time `json:"created_at"`
	// AvatarVersion 0 = avatar yok; her yuklemede artar (istemci onbellegi icin ?v= parametresi).
	AvatarVersion int `json:"avatar_version"`
}

func newUID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return "srv-" + hex.EncodeToString(b)
}

func cleanProfileName(s string) (string, bool) {
	s = strings.TrimSpace(s)
	n := len([]rune(s))
	return s, n >= 1 && n <= 40
}

// profileNameKey ad karsilastirma anahtari: Turkce katlama (FoldTR; Postgres lower() I/İ'de
// collation'a baglidir) + bas/son ve ic bosluk sadelestirme. "İstanbul" == " istanbul ".
func profileNameKey(s string) string {
	return strings.Join(strings.Fields(receiptparse.FoldTR(s)), " ")
}

// profileNameTaken: kullanicinin (exceptID haric) ayni anahtarli bir profili var mi?
// Cagiran profil advisory lock'unu tutmalidir.
func profileNameTaken(q queryer, userID, exceptID int64, name string) (bool, error) {
	rows, err := q.Query(`SELECT name FROM expense.profiles WHERE user_id = $1 AND id <> $2`, userID, exceptID)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	key := profileNameKey(name)
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return false, err
		}
		if profileNameKey(n) == key {
			return true, nil
		}
	}
	return false, rows.Err()
}

func lockProfiles(tx *sql.Tx, userID int64) error {
	_, err := tx.Exec(`SELECT pg_advisory_xact_lock(hashtext($1))`, "profiles|"+strconv.FormatInt(userID, 10))
	return err
}

// ensureProfiles kullanicinin profillerini dondurur; hic yoksa varsayilan "Kisisel" profili olusturur.
// pg_advisory_xact_lock sayesinde eszamanli iki cagri tek varsayilan profil uretir.
func (h *handler) ensureProfiles(userID int64) ([]profileOut, error) {
	tx, err := h.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`SELECT pg_advisory_xact_lock(hashtext($1))`, "profiles|"+strconv.FormatInt(userID, 10)); err != nil {
		return nil, err
	}
	list, err := queryProfiles(tx, userID)
	if err != nil {
		return nil, err
	}
	if len(list) == 0 {
		if _, err := tx.Exec(
			`INSERT INTO expense.profiles (user_id, name, client_uid) VALUES ($1,$2,$3) ON CONFLICT (user_id, client_uid) DO NOTHING`,
			userID, defaultProfileName, "srv-default-"+strconv.FormatInt(userID, 10)); err != nil {
			return nil, err
		}
		if list, err = queryProfiles(tx, userID); err != nil {
			return nil, err
		}
	}
	return list, tx.Commit()
}

func queryProfiles(q queryer, userID int64) ([]profileOut, error) {
	rows, err := q.Query(`SELECT id, name, client_uid, created_at, (CASE WHEN avatar IS NULL THEN 0 ELSE avatar_version END) FROM expense.profiles WHERE user_id = $1 ORDER BY id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []profileOut{}
	for rows.Next() {
		var p profileOut
		if err := rows.Scan(&p.ID, &p.Name, &p.ClientUID, &p.CreatedAt, &p.AvatarVersion); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// resolveProfile: id==0 ise kullanicinin varsayilan (en eski) profili, aksi halde sahiplik dogrulanir.
// Bulunamazsa (veya baskasinin ise) found=false.
func (h *handler) resolveProfile(userID, id int64) (pid int64, found bool, err error) {
	if id == 0 {
		list, err := h.ensureProfiles(userID)
		if err != nil || len(list) == 0 {
			return 0, false, err
		}
		return list[0].ID, true, nil
	}
	err = h.db.QueryRow(`SELECT id FROM expense.profiles WHERE id = $1 AND user_id = $2`, id, userID).Scan(&pid)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	return pid, err == nil, err
}

func (h *handler) listProfiles(c *gin.Context) {
	list, err := h.ensureProfiles(c.GetInt64("userID"))
	if err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, list)
}

// createProfile: client_uid verilirse idempotent (ayni uid icin mevcut profil 200 ile doner).
func (h *handler) createProfile(c *gin.Context) {
	var in struct {
		Name      string `json:"name"`
		ClientUID string `json:"client_uid"`
	}
	if err := c.ShouldBindJSON(&in); err != nil {
		badRequest(c, "invalid request body")
		return
	}
	name, ok := cleanProfileName(in.Name)
	if !ok {
		badRequest(c, "name must be 1-40 characters")
		return
	}
	uid := in.ClientUID
	if uid == "" {
		uid = newUID()
	} else if !clientUIDRe.MatchString(uid) {
		badRequest(c, "invalid client_uid")
		return
	}
	userID := c.GetInt64("userID")

	tx, err := h.db.Begin()
	if err != nil {
		serverError(c)
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`SELECT pg_advisory_xact_lock(hashtext($1))`, "profiles|"+strconv.FormatInt(userID, 10)); err != nil {
		serverError(c)
		return
	}
	var existing profileOut
	err = tx.QueryRow(`SELECT id, name, client_uid, created_at, (CASE WHEN avatar IS NULL THEN 0 ELSE avatar_version END) FROM expense.profiles WHERE user_id=$1 AND client_uid=$2`, userID, uid).
		Scan(&existing.ID, &existing.Name, &existing.ClientUID, &existing.CreatedAt, &existing.AvatarVersion)
	if err == nil {
		c.JSON(http.StatusOK, existing)
		return
	}
	if !errors.Is(err, sql.ErrNoRows) {
		serverError(c)
		return
	}
	var n int
	if err := tx.QueryRow(`SELECT count(*) FROM expense.profiles WHERE user_id=$1`, userID).Scan(&n); err != nil {
		serverError(c)
		return
	}
	if n >= maxProfilesPerUser {
		c.JSON(http.StatusConflict, gin.H{"error": "too many profiles", "code": codeProfileLimit})
		return
	}
	if taken, err := profileNameTaken(tx, userID, 0, name); err != nil {
		serverError(c)
		return
	} else if taken {
		c.JSON(http.StatusConflict, gin.H{"error": "profile name already exists", "code": codeDuplicateProfileName})
		return
	}
	var p profileOut
	if err := tx.QueryRow(
		`INSERT INTO expense.profiles (user_id, name, client_uid) VALUES ($1,$2,$3) RETURNING id, name, client_uid, created_at, (CASE WHEN avatar IS NULL THEN 0 ELSE avatar_version END)`,
		userID, name, uid).Scan(&p.ID, &p.Name, &p.ClientUID, &p.CreatedAt, &p.AvatarVersion); err != nil {
		serverError(c)
		return
	}
	if err := tx.Commit(); err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusCreated, p)
}

func (h *handler) renameProfile(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		badRequest(c, "invalid id")
		return
	}
	var in struct {
		Name string `json:"name"`
	}
	if err := c.ShouldBindJSON(&in); err != nil {
		badRequest(c, "invalid request body")
		return
	}
	name, ok := cleanProfileName(in.Name)
	if !ok {
		badRequest(c, "name must be 1-40 characters")
		return
	}
	userID := c.GetInt64("userID")
	tx, err := h.db.Begin()
	if err != nil {
		serverError(c)
		return
	}
	defer tx.Rollback()
	if err := lockProfiles(tx, userID); err != nil {
		serverError(c)
		return
	}
	var exists bool
	if err := tx.QueryRow(`SELECT EXISTS (SELECT 1 FROM expense.profiles WHERE id=$1 AND user_id=$2)`, id, userID).Scan(&exists); err != nil {
		serverError(c)
		return
	}
	if !exists {
		c.JSON(http.StatusNotFound, gin.H{"error": "profile not found", "code": codeProfileNotFound})
		return
	}
	// Kendisi haric: ayni profilin harf degistirerek yeniden adlandirilmasi serbesttir.
	if taken, err := profileNameTaken(tx, userID, id, name); err != nil {
		serverError(c)
		return
	} else if taken {
		c.JSON(http.StatusConflict, gin.H{"error": "profile name already exists", "code": codeDuplicateProfileName})
		return
	}
	var p profileOut
	if err := tx.QueryRow(
		`UPDATE expense.profiles SET name=$1 WHERE id=$2 AND user_id=$3 RETURNING id, name, client_uid, created_at, (CASE WHEN avatar IS NULL THEN 0 ELSE avatar_version END)`,
		name, id, userID).Scan(&p.ID, &p.Name, &p.ClientUID, &p.CreatedAt, &p.AvatarVersion); err != nil {
		serverError(c)
		return
	}
	if err := tx.Commit(); err != nil {
		serverError(c)
		return
	}
	c.JSON(http.StatusOK, p)
}

func (h *handler) deleteProfile(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		badRequest(c, "invalid id")
		return
	}
	userID := c.GetInt64("userID")
	tx, err := h.db.Begin()
	if err != nil {
		serverError(c)
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`SELECT pg_advisory_xact_lock(hashtext($1))`, "profiles|"+strconv.FormatInt(userID, 10)); err != nil {
		serverError(c)
		return
	}
	var owned bool
	var n int
	if err := tx.QueryRow(`SELECT count(*), COALESCE(bool_or(id = $2), false) FROM expense.profiles WHERE user_id=$1`, userID, id).Scan(&n, &owned); err != nil {
		serverError(c)
		return
	}
	if !owned {
		c.JSON(http.StatusNotFound, gin.H{"error": "profile not found"})
		return
	}
	if n <= 1 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "cannot delete the last profile", "code": "last_profile"})
		return
	}
	if _, err := tx.Exec(`DELETE FROM expense.profiles WHERE id=$1 AND user_id=$2`, id, userID); err != nil {
		serverError(c)
		return
	}
	if err := tx.Commit(); err != nil {
		serverError(c)
		return
	}
	c.Status(http.StatusNoContent)
}

func isUniqueViolation(err error) bool {
	var pqErr *pq.Error
	return errors.As(err, &pqErr) && pqErr.Code == "23505"
}
