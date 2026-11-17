package main

import (
	"bytes"
	"fmt"
	"mime/multipart"
	"net/http/httptest"
	"testing"
)

// Profil avatari (gercek Postgres; FISSIO_TEST_DATABASE_URL gerekir, aksi halde atlanir).

func (e *xenv) putAvatar(uid, profileID int64, data []byte) (int, []byte) {
	e.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, _ := mw.CreateFormFile("file", "a.png")
	_, _ = fw.Write(data)
	_ = mw.Close()
	req := httptest.NewRequest("PUT", fmt.Sprintf("/profiles/%d/avatar", profileID), &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+e.token(uid))
	w := httptest.NewRecorder()
	e.r.ServeHTTP(w, req)
	return w.Code, w.Body.Bytes()
}

func TestPGProfileAvatar(t *testing.T) {
	e := newXEnv(t)
	const alice, bob = int64(1), int64(2)
	ap := e.profiles(alice)[0]
	bp := e.profiles(bob)[0]
	path := fmt.Sprintf("/profiles/%d/avatar", ap.ID)

	if ap.AvatarVersion != 0 {
		t.Fatalf("yeni profilde avatar olmamali: %d", ap.AvatarVersion)
	}
	if code, b := e.as(alice, "GET", path, nil); code != 404 {
		t.Fatalf("avatar yokken GET 404 olmali: %d %s", code, b)
	}

	code, b := e.putAvatar(alice, ap.ID, tinyPNG)
	e.want(code, 200, b, "avatar yukle")
	if got := e.profiles(alice)[0].AvatarVersion; got != 1 {
		t.Fatalf("avatar_version=%d want 1", got)
	}
	code, b = e.as(alice, "GET", path, nil)
	e.want(code, 200, b, "avatar oku")
	if !bytes.Equal(b, tinyPNG) {
		t.Fatalf("avatar icerigi degisti")
	}

	// Yeniden yukleme surumu artirir (onbellek kirilir).
	code, b = e.putAvatar(alice, ap.ID, tinyPNG)
	e.want(code, 200, b, "avatar tekrar yukle")
	if got := e.profiles(alice)[0].AvatarVersion; got != 2 {
		t.Fatalf("avatar_version=%d want 2", got)
	}

	// Baska hesap: okuma/yazma/silme 404; avatar bozulmaz.
	if code, b := e.as(bob, "GET", path, nil); code != 404 {
		t.Fatalf("bob alice avatarini okuyamaz: %d %s", code, b)
	}
	if code, b := e.putAvatar(bob, ap.ID, tinyPNG); code != 404 {
		t.Fatalf("bob alice profiline yazamaz: %d %s", code, b)
	}
	if code, b := e.as(bob, "DELETE", path, nil); code != 404 {
		t.Fatalf("bob alice avatarini silemez: %d %s", code, b)
	}
	if got := e.profiles(bob)[0]; got.ID != bp.ID || got.AvatarVersion != 0 {
		t.Fatalf("bob profili etkilenmemeli: %+v", got)
	}

	// Gecersiz icerik ve boyut.
	if code, b := e.putAvatar(alice, ap.ID, []byte("GIF89a not allowed")); code != 400 {
		t.Fatalf("izin verilmeyen tur 400 olmali: %d %s", code, b)
	}
	if code, b := e.putAvatar(alice, ap.ID, append(append([]byte{}, tinyPNG...), make([]byte, maxAvatarBytes)...)); code != 413 {
		t.Fatalf("buyuk avatar 413 olmali: %d %s", code, b)
	}

	// Silme: surum 0'a doner, GET 404; yeniden yuklemede surum onceki degerlerle cakismaz.
	code, b = e.as(alice, "DELETE", path, nil)
	e.want(code, 200, b, "avatar sil")
	if got := e.profiles(alice)[0].AvatarVersion; got != 0 {
		t.Fatalf("silince avatar_version=%d want 0", got)
	}
	if code, _ := e.as(alice, "GET", path, nil); code != 404 {
		t.Fatalf("silinen avatar 404 olmali: %d", code)
	}
	e.putAvatar(alice, ap.ID, tinyPNG)
	if got := e.profiles(alice)[0].AvatarVersion; got <= 2 {
		t.Fatalf("yeniden yuklemede surum geri sarilmamali: %d", got)
	}

	// Profil silinince avatar da gider (ikinci profil uzerinde).
	second := e.newProfile(alice, "Ev")
	e.putAvatar(alice, second.ID, tinyPNG)
	code, b = e.as(alice, "DELETE", fmt.Sprintf("/profiles/%d", second.ID), nil)
	e.want(code, 204, b, "profil sil")
	if code, _ := e.as(alice, "GET", fmt.Sprintf("/profiles/%d/avatar", second.ID), nil); code != 404 {
		t.Fatalf("silinen profilin avatari 404 olmali: %d", code)
	}
}
