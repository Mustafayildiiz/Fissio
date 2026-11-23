package main

import (
	"strings"
	"testing"
	"time"
)

func TestShouldNotifyFailure(t *testing.T) {
	cases := []struct {
		status, reason string
		want           bool
	}{
		{historyFailed, "db_error: boom", true},
		{historyIgnored, "no_amount", true},
		{historyIgnored, "pdf_unreadable", true},
		{historyIgnored, "paused", true},
		{historyIgnored, rejectedTooLarge, true},
		{historyIgnored, "rate_limited", true},
		{historyIgnored, "invalid:amount", true},
		{historyIgnored, "duplicate_document", false},
		{historyIgnored, "duplicate_order", false},
		{historyIgnored, "already_imported", false},
		{historyIgnored, "gmail_confirmation", false},
		{historyIgnored, "gmail_confirmation_unreadable", false},
		{historySaved, "created", false},
		{historySaved, "merged", false},
	}
	for _, c := range cases {
		if got := shouldNotifyFailure(c.status, c.reason); got != c.want {
			t.Errorf("shouldNotifyFailure(%q,%q)=%v want %v", c.status, c.reason, got, c.want)
		}
	}
}

func TestInboundReasonTextHidesInternalError(t *testing.T) {
	txt := inboundReasonText(historyFailed, "db_error: pq: secret detail")
	if strings.Contains(txt, "secret") || !strings.Contains(txt, "db_error") {
		t.Fatalf("iç hata metni sızmamalı: %q", txt)
	}
	if txt := inboundReasonText(historyIgnored, "no_amount"); !strings.Contains(txt, "tutar") {
		t.Fatalf("no_amount: %q", txt)
	}
}

func TestAuthFailureNotifierSendsToAuth(t *testing.T) {
	fa := newFakeAuth(t)
	n := newAuthFailureNotifier(fa.url(), testInternalToken, 4)
	at := time.Date(2026, 11, 23, 10, 0, 0, 0, time.UTC)
	if !n.Enqueue(failureNotice{UserID: 42, ProfileName: "İş", MailSubject: "Fatura", ReceivedAt: at, Reason: "E-postada fiş tutarı bulunamadı."}) {
		t.Fatal("enqueue")
	}
	deadline := time.Now().Add(3 * time.Second)
	for len(fa.noticeList()) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	got := fa.noticeList()
	if len(got) != 1 || got[0].UserID != 42 || got[0].Body["profile_name"] != "İş" || got[0].Body["mail_subject"] != "Fatura" ||
		got[0].Body["reason"] == "" || got[0].Body["received_at"] != "2026-11-23T10:00:00Z" {
		t.Fatalf("auth'a giden bildirim: %+v", got)
	}
	if fa.hitCount() != 0 {
		t.Fatal("bildirim oturum sayacını etkilememeli")
	}
}

func TestAuthFailureNotifierDropsWhenFull(t *testing.T) {
	n := &authFailureNotifier{ch: make(chan failureNotice, 1)} // worker yok: kuyruk dolar
	if !n.Enqueue(failureNotice{UserID: 1}) {
		t.Fatal("ilk kayıt kuyruğa girmeli")
	}
	if n.Enqueue(failureNotice{UserID: 1}) {
		t.Fatal("dolu kuyruk bloklamadan reddetmeli")
	}
}
