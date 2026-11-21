package digital

import (
	"regexp"
	"strings"
)

var (
	fwdMarkerRe = regexp.MustCompile(`forwarded message|begin forwarded|iletilen ileti|iletilmis mesaj|original message|orijinal mesaj|orijinal ileti`)
	// Başlık bloğu satırı (katlanmış): Gmail/Outlook/Apple/Türkçe istemciler.
	hdrLineRe  = regexp.MustCompile(`^(?:from|to|cc|bcc|date|sent|subject|reply-to|gonderen|kimden|kime|alici|konu|tarih|gonderilme|gonderim tarihi|gonderildi|gonderilme tarihi)\s*:`)
	hdrFromRe  = regexp.MustCompile(`^(?:from|gonderen|kimden)\s*:`)
	quotePfxRe = regexp.MustCompile(`^(?:>\s?)+`)
)

// StripForwardPreamble "İlet (Forward)" ile eklenen önsözü atar: "---------- Forwarded message ---------",
// "Begin forwarded message:", "İletilen ileti", Outlook "From:/Sent:/To:/Subject:" başlık bloğu ve satır başı ">"
// alıntı işaretleri. Aksi halde bu bloklar işletme adı/tarih olarak yanlış okunurdu. Dart ikizi: html_text.dart.
func StripForwardPreamble(text string) string {
	lines := splitCRLF(text)

	// Alıntı işaretleri: boş olmayan satırların çoğu ">" ile başlıyorsa kaldır.
	nonEmpty, quoted := 0, 0
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if t == "" {
			continue
		}
		nonEmpty++
		if strings.HasPrefix(t, ">") {
			quoted++
		}
	}
	if nonEmpty > 0 && quoted*2 >= nonEmpty {
		for i, l := range lines {
			lines[i] = strings.TrimSpace(quotePfxRe.ReplaceAllString(strings.TrimSpace(l), ""))
		}
	}

	limit := len(lines)
	if limit > 60 {
		limit = 60
	}
	cut := -1
	for i := 0; i < limit; i++ {
		if fwdMarkerRe.MatchString(fold(lines[i])) {
			cut = skipHeaderBlock(lines, i+1)
			break
		}
	}
	if cut < 0 {
		// İşaretsiz başlık bloğu: ilk dolu satırlardan başlayan ≥3 ardışık başlık satırı ve içinde "From".
		start := 0
		for start < len(lines) && strings.TrimSpace(lines[start]) == "" {
			start++
		}
		end := skipHeaderBlock(lines, start)
		count, hasFrom := 0, false
		for k := start; k < end; k++ {
			f := fold(strings.TrimSpace(lines[k]))
			if hdrLineRe.MatchString(f) {
				count++
				if hdrFromRe.MatchString(f) {
					hasFrom = true
				}
			}
		}
		if count >= 3 && hasFrom {
			cut = end
		}
	}
	if cut > 0 {
		lines = lines[cut:]
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

// skipHeaderBlock `from` konumundan başlayarak başlık satırlarını (ve aralarındaki boş satırları) atlar.
func skipHeaderBlock(lines []string, from int) int {
	j := from
	for j < len(lines) {
		t := strings.TrimSpace(lines[j])
		if t == "" {
			j++
			continue
		}
		if hdrLineRe.MatchString(fold(t)) {
			j++
			continue
		}
		break
	}
	return j
}
