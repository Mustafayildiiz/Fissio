package main

import (
	"database/sql"
	"errors"
	"net/http"
	"net/mail"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/lib/pq"
	"golang.org/x/crypto/bcrypt"
)

type handler struct {
	db        *sql.DB
	secret    []byte
	dummyHash []byte
}

type credentials struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func (h *handler) register(c *gin.Context) {
	var in credentials
	if err := c.ShouldBindJSON(&in); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}
	email := strings.ToLower(strings.TrimSpace(in.Email))
	if _, err := mail.ParseAddress(email); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid email"})
		return
	}
	// bcrypt 72 baytin ustunu kabul etmez.
	if len(in.Password) < 6 || len(in.Password) > 72 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "password must be 6-72 characters"})
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(in.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "could not hash password"})
		return
	}

	var id int64
	var created time.Time
	err = h.db.QueryRow(
		`INSERT INTO auth.users (email, password_hash) VALUES ($1, $2) RETURNING id, created_at`,
		email, string(hash)).Scan(&id, &created)
	if err != nil {
		var pqErr *pq.Error
		if errors.As(err, &pqErr) && pqErr.Code == "23505" {
			c.JSON(http.StatusConflict, gin.H{"error": "email already registered"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "could not create user"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{"id": id, "email": email, "created_at": created})
}

func (h *handler) login(c *gin.Context) {
	var in credentials
	if err := c.ShouldBindJSON(&in); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}
	email := strings.ToLower(strings.TrimSpace(in.Email))

	var id int64
	var hash string
	err := h.db.QueryRow(`SELECT id, password_hash FROM auth.users WHERE email = $1`, email).Scan(&id, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		// Zamanlama farkindan kullanici varligi sizmasin diye sahte karsilastirma.
		_ = bcrypt.CompareHashAndPassword(h.dummyHash, []byte(in.Password))
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid email or password"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(in.Password)) != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid email or password"})
		return
	}

	token, exp, err := issueToken(h.secret, id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "could not issue token"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"token": token, "expires_at": exp, "user": gin.H{"id": id, "email": email}})
}

func (h *handler) me(c *gin.Context) {
	id := c.GetInt64("userID")
	var email string
	var created time.Time
	err := h.db.QueryRow(`SELECT email, created_at FROM auth.users WHERE id = $1`, id).Scan(&email, &created)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"id": id, "email": email, "created_at": created})
}
