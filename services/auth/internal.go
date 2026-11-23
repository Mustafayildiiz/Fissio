package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/lib/pq"
)

// internalTokenHeader servisler arasi cagrilarin paylasilan gizli anahtari (INTERNAL_TOKEN).
const internalTokenHeader = "X-Internal-Token"

// deletionSweepGrace: hesap silme istegindeki oturum iptalinden sonra beklenen sure. expense oturum sonucunu
// ~10 sn onbellekler; bu sureden sonra yapilan son temizlik, onbellekten gecen yazmalarin yetim veri
// birakmasini engeller.
const deletionSweepGrace = 30 * time.Second

// userPurger bir kullanicinin diger servislerdeki (expense) verisini siler. auth, expense semasina SQL atmaz.
type userPurger interface {
	PurgeUser(ctx context.Context, userID int64) error
}

// httpPurger expense'in ic API'sini (DELETE /internal/users/:id) cagirir.
type httpPurger struct {
	baseURL string
	token   string
	client  *http.Client
}

func newHTTPPurger(baseURL, token string) *httpPurger {
	return &httpPurger{
		baseURL: strings.TrimRight(baseURL, "/"),
		token:   token,
		client:  &http.Client{Timeout: 20 * time.Second},
	}
}

func (p *httpPurger) PurgeUser(ctx context.Context, userID int64) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, fmt.Sprintf("%s/internal/users/%d", p.baseURL, userID), nil)
	if err != nil {
		return err
	}
	req.Header.Set(internalTokenHeader, p.token)
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("expense purge returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

// internalAuth paylasilan INTERNAL_TOKEN'i sabit zamanli karsilastirir. Bos token tum istekleri reddeder.
func internalAuth(token string) gin.HandlerFunc {
	want := []byte(token)
	return func(c *gin.Context) {
		got := []byte(c.GetHeader(internalTokenHeader))
		if len(want) == 0 || subtle.ConstantTimeCompare(got, want) != 1 {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized", "code": "unauthorized"})
			return
		}
		c.Next()
	}
}

// buildInternalRouter servisler arasi (expense -> auth) rotalar. Ayri bir portta (INTERNAL_PORT, varsayilan 9090)
// dinlenir ve docker-compose'ta host'a YAYINLANMAZ; ek olarak INTERNAL_TOKEN ister.
func buildInternalRouter(h *handler) *gin.Engine {
	r := gin.New()
	r.Use(gin.Recovery())
	r.GET("/health", func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"service": "auth-internal", "status": "ok"}) })
	in := r.Group("/internal", internalAuth(h.cfg.internalToken))
	in.GET("/sessions/:sid", h.internalSession)
	in.POST("/users/:id/inbound-failure", h.internalInboundFailure)
	return r
}

// internalSession GET /internal/sessions/:sid -> {alive, user_id}. expense, access token'daki sid'in hala acik ve
// token sahibine ait oldugunu buradan dogrular (auth semasina dogrudan SQL yerine). Bilinmeyen oturum 404,
// bicimi bozuk sid 400 doner. Silinmekte olan hesabin oturumlari zaten iptal edilmistir.
func (h *handler) internalSession(c *gin.Context) {
	var userID int64
	var alive bool
	err := h.db.QueryRow(
		`SELECT user_id, revoked_at IS NULL FROM auth.sessions WHERE id = $1::uuid`, c.Param("sid")).Scan(&userID, &alive)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		fail(c, http.StatusNotFound, "not_found", "session not found")
		return
	case isInvalidUUID(err):
		fail(c, http.StatusBadRequest, "bad_request", "invalid session id")
		return
	case err != nil:
		internalErr(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"alive": alive, "user_id": userID})
}

func isInvalidUUID(err error) bool {
	var pqErr *pq.Error
	return errors.As(err, &pqErr) && pqErr.Code == "22P02" // invalid_text_representation
}

// sweepDeletions "silinmekte" isaretli (deleting_at dolu) ve bekleme suresini doldurmus hesaplari tamamlar:
// ilk deneme (expense erisilemezdi vb.) basarisiz olduysa dakikada bir yeniden denenir.
func (h *handler) sweepDeletions(ctx context.Context) {
	rows, err := h.db.Query(`SELECT id FROM auth.users WHERE deleting_at IS NOT NULL AND deleting_at < now() - $1::interval`,
		fmt.Sprintf("%d seconds", int(deletionSweepGrace.Seconds())))
	if err != nil {
		log.Printf("deletion sweep: %v", err)
		return
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	for _, id := range ids {
		if err := h.finishAccountDeletion(ctx, id); err != nil {
			log.Printf("deletion sweep: user %d: %v", id, err)
		}
	}
}

// runDeletionSweeper dakikada bir sweepDeletions calistirir (ctx iptal edilene kadar).
func (h *handler) runDeletionSweeper(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			h.sweepDeletions(ctx)
		}
	}
}
