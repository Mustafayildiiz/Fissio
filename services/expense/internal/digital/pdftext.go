package digital

import (
	"bytes"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/ledongthuc/pdf"
)

const (
	maxPDFBytes = 20 << 20
	maxPDFPages = 20
)

var ErrPDFUnreadable = errors.New("pdf unreadable")

// PDFPageTexts metin katmanlı bir PDF'in sayfa metinlerini satır yapısıyla döndürür. Güvenilmeyen girdiyi
// ayrıştırdığı için panikleri yakalar (retry döngüsüne yol açmasın) ve boyut/sayfa tavanı uygular.
func PDFPageTexts(data []byte) (pages []string, err error) {
	if len(data) == 0 || len(data) > maxPDFBytes {
		return nil, ErrPDFUnreadable
	}
	defer func() {
		if r := recover(); r != nil {
			pages, err = nil, fmt.Errorf("%w: %v", ErrPDFUnreadable, r)
		}
	}()
	r, err := pdf.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrPDFUnreadable, err)
	}
	n := r.NumPage()
	if n > maxPDFPages {
		n = maxPDFPages
	}
	for i := 1; i <= n; i++ {
		rows, err := r.Page(i).GetTextByRow()
		if err != nil {
			continue
		}
		pages = append(pages, rowsToText(rows))
	}
	return pages, nil
}

// rowsToText satırları yukarıdan aşağıya birleştirir; Y farkı ≤2 pt olan satırları tek satır sayar.
func rowsToText(rows pdf.Rows) string {
	type line struct {
		y     int64
		parts []pdf.Text
	}
	var lines []*line
	for _, row := range rows {
		var cur *line
		for _, l := range lines {
			d := l.y - row.Position
			if d < 0 {
				d = -d
			}
			if d <= 2 {
				cur = l
				break
			}
		}
		if cur == nil {
			cur = &line{y: row.Position}
			lines = append(lines, cur)
		}
		cur.parts = append(cur.parts, row.Content...)
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].y > lines[j].y })
	var out []string
	for _, l := range lines {
		sort.SliceStable(l.parts, func(i, j int) bool { return l.parts[i].X < l.parts[j].X })
		var sb strings.Builder
		for _, p := range l.parts {
			s := strings.TrimSpace(p.S)
			if s == "" {
				continue
			}
			if sb.Len() > 0 {
				sb.WriteByte(' ')
			}
			sb.WriteString(s)
		}
		if t := strings.TrimSpace(sb.String()); t != "" {
			out = append(out, t)
		}
	}
	return strings.Join(out, "\n")
}
