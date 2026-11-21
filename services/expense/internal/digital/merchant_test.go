package digital

import "testing"

func TestChooseMerchantPriority(t *testing.T) {
	mk := func(from, text string) *Message { return &Message{From: from, Text: text} }
	cases := []struct {
		name   string
		parsed string
		body   string
		m      *Message
		want   string
	}{
		{"etiketli satır kazanır", "Restoran Köşebaşı Döner", "Sipariş\nRestoran Köşebaşı Döner\nToplam 10,00", mk("Yemek <a@yemek.example>", ""), "Köşebaşı Döner"},
		{"iki noktalı etiket", "", "Satıcı: Ahmet Usta Ltd.\nToplam 10,00", mk("", ""), "Ahmet Usta Ltd."},
		{"mağaza etiketi", "x", "Mağaza - Migros Kadıköy\nToplam 10,00", mk("", ""), "Migros Kadıköy"},
		{"ayrıştırıcı kısa ad", "Köşebaşı Döner", "…", mk("Platform <a@p.example>", ""), "Köşebaşı Döner"},
		{"A101 gibi rakamlı gerçek ad korunur", "A101", "…", mk("Platform <a@p.example>", ""), "A101"},
		{"uzun cümle → gönderen adı", "GetirYemek ile verdiğin siparişin teslim edildi, afiyet olsun", "…", mk("GetirYemek <noreply@getiryemek.example>", ""), "GetirYemek"},
		{"sipariş numarası → gönderen adı", "Sipariş No: 4F7A91C2", "…", mk("Ürün Satış <noreply@x.example>", ""), "Ürün Satış"},
		{"ayrıştırıcı boş → gönderen adı", "", "…", mk("Mağazam Online <a@b.example>", ""), "Mağazam Online"},
		{"ad yok → domain", "", "…", mk("noreply@getiryemek.com", ""), "Getiryemek"},
		{"com.tr domain", "", "…", mk("info@mail.siparis.getir.com.tr", ""), "Getir"},
		{"kişisel posta sağlayıcısı satıcı olmaz", "", "…", mk("Mustafa Y <kisi@gmail.com>", ""), ""},
		{"kişisel adres ve cümle", "Sipariş No: 12345678 teslim edildi.", "…", mk("kisi@hotmail.com", ""), ""},
		{"m nil + cümle", "Bu çok uzun bir cümledir ve işletme adı değildir elbette", "…", nil, ""},
	}
	for _, c := range cases {
		if got := ChooseMerchant(c.parsed, c.body, c.m); got != c.want {
			t.Errorf("%s: ChooseMerchant = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestChooseMerchantForwardedPreamble(t *testing.T) {
	// Elle iletilmiş mail: From kullanıcının kendisi (gmail), özgün gönderici önsözde.
	fwd := "---------- Forwarded message ---------\nFrom: GetirYemek <noreply@getiryemek.example>\nDate: Sat, 21 Nov 2026\nSubject: Siparişin\nTo: kisi@gmail.com\n\nSipariş Özeti\nToplam 355,00"
	m := &Message{From: "Mustafa Y <kisi@gmail.com>", Text: fwd}
	if got := ChooseMerchant("Sipariş Özeti Toplam tutarı hazırlandı, teşekkürler.", StripForwardPreamble(fwd), m); got != "GetirYemek" {
		t.Fatalf("önsözdeki Gönderen: görünen adı beklenir, got %q", got)
	}
	// Türkçe başlık + yalnız adres: domain adı.
	tr := "İletilen ileti\nGönderen: <fatura@abluka.example>\nKonu: Fatura\n\nToplam 1,00"
	if got := OriginalSender(&Message{Text: tr}); got != "Abluka" {
		t.Fatalf("domain adı beklenir, got %q", got)
	}
	// Önsözdeki gönderici kişisel posta: satıcı sayılmaz.
	if got := OriginalSender(&Message{Text: "---------- Forwarded message ---------\nFrom: Ali <ali@gmail.com>\nSubject: x\n"}); got != "" {
		t.Fatalf("kişisel gönderici satıcı olmaz, got %q", got)
	}
	// HTML gövdede önsöz.
	h := &Message{HTML: "<div>---------- Forwarded message ---------</div><div>From: <b>Trendyol Go</b> &lt;no-reply@trendyolgo.example&gt;</div><div>Subject: x</div>"}
	if got := OriginalSender(h); got != "Trendyol Go" {
		t.Fatalf("HTML önsözü, got %q", got)
	}
}

func TestLooksLikeSentence(t *testing.T) {
	no := []string{"Migros", "A101", "7-Eleven", "Köşebaşı Döner", "CarrefourSA", "Shell Petrol A.Ş."}
	yes := []string{"", "Sipariş No 4F7A91C2", "#12345678", "Siparişiniz hazırlanıyor, afiyet olsun.", "1234567890", "Bu bir uzun cümle değil mi acaba işletme", "Teşekkürler:"}
	for _, s := range no {
		if looksLikeSentence(s) {
			t.Errorf("%q işletme adı olmalı", s)
		}
	}
	for _, s := range yes {
		if !looksLikeSentence(s) {
			t.Errorf("%q cümle/numara sayılmalı", s)
		}
	}
}

func TestProductLinesWithQty(t *testing.T) {
	text := "Siparişiniz\nTavukburger® Menü Alana Tavukburger® Menü Hediye - (Adet: 1)\nAyran (Adet: 3)\nAra Toplam 665,00\n(Adet: 2)\nX (Adet: 1)"
	got := ProductLinesWithQty(text)
	want := []ProductLine{{"Tavukburger® Menü Alana Tavukburger® Menü Hediye", 1}, {"Ayran", 3}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("line %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	if ProductLinesWithQty("Toplam 355,00") != nil {
		t.Error("adetsiz metin ürün satırı üretmemeli")
	}
}
