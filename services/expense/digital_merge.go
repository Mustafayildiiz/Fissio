package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"time"

	"fissio/expense/internal/digital"
)

// Dijital fiş akıllı birleştirme (ön özet + resmi fatura) — sunucu tarafı. Karar saf `digital.DecideMerge`'tedir (Dart ikizi:
// merge_decision.dart, ortak vektörler testdata/merge_decision.json); burası yalnızca adayları yükler ve kararı uygular.
// POST /expenses, POST /expenses/bulk ve inbound e-posta webhook'u AYNI yolu kullanır.

type dbQuerier interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
	Exec(query string, args ...any) (sql.Result, error)
}

// mergeDecision decideIncoming sonucu.
type mergeDecision struct {
	digital.Decision
	// ByDocument: duplicate kararı aynı document_no yüzünden mi (409 duplicate_document), yoksa order_id yüzünden mü.
	ByDocument bool
	// Replay: aynı client_uid daha önce bu hedefe birleştirilmişti (yanıtı kaybolan isteğin tekrarı): yeniden uygulanmaz.
	Replay bool
}

func (in *expenseInput) digitalDoc(d time.Time) digital.Doc {
	doc := digital.Doc{
		Merchant:    in.Merchant,
		AmountCents: int64(math.Round(in.Amount * 100)),
		Date:        d.Format(dateLayout),
	}
	if in.DocumentNo != nil {
		doc.DocumentNo = *in.DocumentNo
	}
	if in.OrderID != nil {
		doc.OrderID = *in.OrderID
	}
	for _, it := range in.Items {
		doc.Items = append(doc.Items, it.Name)
	}
	return doc
}

// loadMergeCandidates gelen belgeyle ilgili olabilecek kayıtları kilitleyerek okur (aynı document_no, aynı order_id ve —
// gelen RESMİ ise— resmi bağlanmamış, aynı tutarlı ±3 gün içindeki kayıtlar).
func loadMergeCandidates(q dbQuerier, userID int64, in expenseInput, d time.Time) ([]digital.Doc, error) {
	cents := int64(math.Round(in.Amount * 100))
	rows, err := q.Query(
		`SELECT id, merchant, ROUND(amount*100)::bigint, to_char(spent_at,'YYYY-MM-DD'), COALESCE(document_no,''), COALESCE(order_id,''), items
		 FROM expense.expenses
		 WHERE user_id = $1 AND (
		       ($2::text IS NOT NULL AND document_no = $2::text)
		    OR ($3::text IS NOT NULL AND order_id = $3::text)
		    OR ($6::bool AND NOT has_official_invoice AND ROUND(amount*100)::bigint = $4 AND spent_at BETWEEN $5::date - 3 AND $5::date + 3))
		 ORDER BY id FOR UPDATE`,
		userID, in.documentArg(), in.orderArg(), cents, d, in.DocumentNo != nil)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []digital.Doc
	for rows.Next() {
		var c digital.Doc
		var items []byte
		if err := rows.Scan(&c.ID, &c.Merchant, &c.AmountCents, &c.Date, &c.DocumentNo, &c.OrderID, &items); err != nil {
			return nil, err
		}
		var parsed []expenseItem
		if len(items) > 0 && json.Unmarshal(items, &parsed) == nil {
			for _, it := range parsed {
				c.Items = append(c.Items, it.Name)
			}
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// decideIncoming gelen fiş için create | duplicate | merge kararını verir. document_no/order_id taşımayan fişler doğrudan
// create'tir. Aynı client_uid tekrarı (çevrimdışı kuyruk yeniden denemesi) birleştirme/mükerrer sayılmaz: normal ekleme
// yolu onu idempotent çözer.
func decideIncoming(q dbQuerier, userID int64, uid string, in expenseInput, d time.Time) (mergeDecision, error) {
	if in.DocumentNo == nil && in.OrderID == nil {
		return mergeDecision{Decision: digital.Decision{Action: digital.ActionCreate}}, nil
	}
	var exists bool
	if err := q.QueryRow(`SELECT EXISTS(SELECT 1 FROM expense.expenses WHERE user_id = $1 AND client_uid = $2)`, userID, uid).Scan(&exists); err != nil {
		return mergeDecision{}, err
	}
	if exists {
		return mergeDecision{Decision: digital.Decision{Action: digital.ActionCreate}}, nil
	}
	// Bu client_uid daha önce bir ön özete birleştirildiyse (yeni kayıt açılmadığı için client_uid yalnızca hedefte tutulur) tekrar
	// aynı hedefe çözülür: idempotent (çevrimdışı kuyruk / webhook yeniden denemesi mükerrer hatası görmez).
	var target int64
	switch err := q.QueryRow(`SELECT id FROM expense.expenses WHERE user_id = $1 AND $2 = ANY(merged_client_uids) LIMIT 1`, userID, uid).Scan(&target); {
	case err == nil:
		return mergeDecision{Decision: digital.Decision{Action: digital.ActionMerge, TargetID: target}, Replay: true}, nil
	case !errors.Is(err, sql.ErrNoRows):
		return mergeDecision{}, err
	}
	cands, err := loadMergeCandidates(q, userID, in, d)
	if err != nil {
		return mergeDecision{}, err
	}
	dec := digital.DecideMerge(in.digitalDoc(d), cands)
	out := mergeDecision{Decision: dec}
	if dec.Action == digital.ActionDuplicate && in.DocumentNo != nil {
		for _, c := range cands {
			if c.ID == dec.TargetID && c.DocumentNo == *in.DocumentNo {
				out.ByDocument = true
			}
		}
	}
	return out, nil
}

// applyMerge resmi belgeyi hedef ön özet kaydına işler: document_no (⇒ has_official_invoice=true, kayıt kilitlenir),
// order_id (boşsa), amount (resmi kesin toplam), ocr_engine (boşsa) ve — mevcut kayıtta kalem yoksa — kalemler. Kullanıcının
// düzenlediği alanlar (işletme, tarih, kategori, not, mevcut kalemler) ezilmez. document_no IS NULL koşulu kilidi korur.
func applyMerge(q dbQuerier, userID, targetID int64, uid string, in expenseInput, itemsJSON string) error {
	res, err := q.Exec(
		`UPDATE expense.expenses SET document_no = $3::text, order_id = COALESCE(order_id, $4::text), amount = $5,
		        ocr_engine = COALESCE(ocr_engine, $6::text),
		        items = CASE WHEN jsonb_array_length(items) = 0 THEN $7::jsonb ELSE items END,
		        merged_client_uids = array_append(merged_client_uids, $8::text),
		        updated_at = GREATEST(clock_timestamp(), updated_at + interval '1 microsecond')
		 WHERE id = $1 AND user_id = $2 AND document_no IS NULL`,
		targetID, userID, in.documentArg(), in.orderArg(), in.Amount, in.ocrArg(), itemsJSON, uid)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errMergeTargetLocked
	}
	return nil
}

var errMergeTargetLocked = errors.New("merge target already has an official document")

// Yazma sonuçları (writeExpense status).
const (
	writeCreated = "created"
	writeSkipped = "skipped" // aynı client_uid zaten kayıtlı (idempotent tekrar)
	writeMerged  = "merged"
)

// writeExpense fişi ekler, mevcut ön özete birleştirir ya da mükerrer olarak reddeder. dupCode doluysa kayıt yazılmamıştır
// ("duplicate_document" | "duplicate_order") ve id mevcut kaydı gösterir; çağıran SAVEPOINT'e geri dönmelidir (unique ihlali
// işlemi bozmuş olabilir). Diğer hatalar err olarak döner.
func writeExpense(q dbQuerier, userID, profileID int64, uid string, in expenseInput, d time.Time, itemsJSON string) (id int64, status, dupCode string, err error) {
	dec, err := decideIncoming(q, userID, uid, in, d)
	if err != nil {
		return 0, "", "", err
	}
	switch dec.Action {
	case digital.ActionDuplicate:
		code := "duplicate_order"
		if dec.ByDocument {
			code = "duplicate_document"
		}
		return dec.TargetID, "", code, nil
	case digital.ActionMerge:
		if dec.Replay {
			return dec.TargetID, writeMerged, "", nil
		}
		if err := applyMerge(q, userID, dec.TargetID, uid, in, itemsJSON); err != nil {
			if errors.Is(err, errMergeTargetLocked) {
				return dec.TargetID, "", "duplicate_document", nil
			}
			if isDuplicateDocument(err) {
				return dec.TargetID, "", "duplicate_document", nil
			}
			if isDuplicateOrder(err) {
				return dec.TargetID, "", "duplicate_order", nil
			}
			return 0, "", "", err
		}
		return dec.TargetID, writeMerged, "", nil
	}
	id, created, err := insertExpense(q, userID, profileID, uid, in, d, itemsJSON)
	switch {
	case isDuplicateDocument(err):
		return 0, "", "duplicate_document", nil
	case isDuplicateOrder(err):
		return 0, "", "duplicate_order", nil
	case err != nil:
		return 0, "", "", err
	case created:
		return id, writeCreated, "", nil
	}
	return id, writeSkipped, "", nil
}
