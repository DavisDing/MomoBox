package syncpostgres

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"image"
	"image/png"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/momobox/backend/internal/processing"
)

func processingImage(t *testing.T) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 20, 20))); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}
func TestPostgresMediaRetriesTombstonesAndOCR(t *testing.T) {
	f := newImportPostgresFixture(t)
	s := processing.New(f.db, processing.AIConfig{})
	u := processing.Upload{ID: importPlan, EntityType: "product", EntityID: importProduct, MediaType: "instruction_image", Content: processingImage(t)}
	a, err := s.Upload(f.ctx, importFamily, importUser, u)
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Upload(f.ctx, importFamily, importUser, u)
	if err != nil || a.SHA256 != b.SHA256 || !bytes.Equal(a.Content, b.Content) {
		t.Fatalf("retry changed upload: %v", err)
	}
	if _, err := s.Get(f.ctx, importUser, u.ID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("cross-family media exposed", err)
	}

	listed, listErr := s.List(f.ctx, importFamily, "product", importProduct, "")
	if listErr != nil || len(listed) != 1 || len(listed[0].Content) != 0 {
		t.Fatalf("bad metadata page: %#v %v", listed, listErr)
	}
	if err := s.Reassign(f.ctx, importFamily, u.ID, importBatch); !errors.Is(err, processing.ErrConflict) {
		t.Fatal("product-to-product move accepted", err)
	}
	u.Content = []byte("different")
	if _, err := s.Upload(f.ctx, importFamily, importUser, u); !errors.Is(err, processing.ErrConflict) {
		t.Fatal("UUID reuse accepted", err)
	}
	calls := 0
	s.OCR = func(context.Context, []byte) (string, error) { calls++; return "包装文字", nil }
	for i := 0; i < 2; i++ {
		a, err = s.RunOCR(f.ctx, importFamily, u.ID)
		if err != nil || a.OCRStatus != "complete" || a.OCRText != "包装文字" {
			t.Fatalf("OCR failed: %#v %v", a, err)
		}
	}
	if calls != 1 {
		t.Fatal("completed OCR repeated")
	}
	if err := s.Delete(f.ctx, importFamily, u.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RunOCR(f.ctx, importFamily, u.ID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("deleted media OCR accepted", err)
	}
	u.Content = processingImage(t)
	if _, err := s.Upload(f.ctx, importFamily, importUser, u); !errors.Is(err, processing.ErrConflict) {
		t.Fatal("delete resurrected", err)
	}
	u.ID = importBatch
	if err := s.Delete(f.ctx, importFamily, u.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Upload(f.ctx, importFamily, importUser, u); !errors.Is(err, processing.ErrConflict) {
		t.Fatal("delete before upload resurrected", err)
	}
}
func TestPostgresOCRFailureRetryAndDeleteRace(t *testing.T) {
	f := newImportPostgresFixture(t)
	s := processing.New(f.db, processing.AIConfig{})
	u := processing.Upload{ID: importPlan, EntityType: "intake_draft", EntityID: importProduct, MediaType: "product_image", Content: processingImage(t)}
	if _, err := s.Upload(f.ctx, importFamily, importUser, u); err != nil {
		t.Fatal(err)
	}
	s.OCR = func(context.Context, []byte) (string, error) { return "", errors.New("sensitive output") }
	a, err := s.RunOCR(f.ctx, importFamily, u.ID)
	if err != nil || a.OCRStatus != "failed" || strings.Contains(*a.OCRError, "sensitive") {
		t.Fatal("failure not persisted/sanitized", err)
	}
	s.OCR = func(ctx context.Context, _ []byte) (string, error) {
		if err := s.Delete(ctx, importFamily, u.ID); err != nil {
			t.Fatal(err)
		}
		return "must not resurrect", nil
	}
	if _, err := s.RunOCR(f.ctx, importFamily, u.ID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("OCR revived deleted media", err)
	}
}
func TestPostgresOperationHistoryReadOnlyStablePagination(t *testing.T) {
	f := newImportPostgresFixture(t)
	s := processing.New(f.db, processing.AIConfig{})
	f.exec(t, `INSERT INTO products(id,family_id,name) VALUES($1::uuid,$2::uuid,'item')`, importProduct, importFamily)
	f.exec(t, `INSERT INTO product_batches(id,family_id,product_id,quantity,initial_quantity) VALUES($1::uuid,$2::uuid,$3::uuid,7,10)`, importBatch, importFamily, importProduct)
	insert := func(op string) {
		f.exec(t, `INSERT INTO consumption_records(family_id,batch_id,product_id,record_type,quantity_change,operation_id,idempotency_key,created_by_user_id,device_id) VALUES($1::uuid,$2::uuid,$3::uuid,'consume',-1,$4::uuid,$4,$5::uuid,$6::uuid)`, importFamily, importBatch, importProduct, op, importUser, importDevice)
	}
	insert(importPlan)
	insert(importCategory)
	first, err := s.History(f.ctx, importFamily, 0, 0, 1)
	if err != nil || len(first.Records) != 1 || !first.HasMore {
		t.Fatal("first page", first, err)
	}
	insert(importSecondDevice)
	second, err := s.History(f.ctx, importFamily, first.Next, first.Until, 1)
	if err != nil || len(second.Records) != 1 || second.HasMore || second.Records[0].ID == first.Records[0].ID {
		t.Fatal("unstable page", second, err)
	}
	third, err := s.History(f.ctx, importFamily, second.Next, 0, 10)
	if err != nil || len(third.Records) != 1 {
		t.Fatal("lost later history", third, err)
	}
	empty, err := s.History(f.ctx, importUser, 0, 0, 10)
	if err != nil || len(empty.Records) != 0 {
		t.Fatal("cross-family history", err)
	}
	var quantity int
	if err := f.db.QueryRowContext(f.ctx, `SELECT quantity FROM product_batches WHERE id=$1::uuid`, importBatch).Scan(&quantity); err != nil || quantity != 7 {
		t.Fatal("history changed inventory", quantity, err)
	}
}

type processingTransport func(*http.Request) (*http.Response, error)

func (f processingTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestPostgresAIReceiptsSuppressRepeatedPaidRequests(t *testing.T) {
	f := newImportPostgresFixture(t)
	var calls atomic.Int32
	s := processing.New(f.db, processing.AIConfig{Endpoints: []processing.AIEndpoint{{Endpoint: "http://model.local/v1", Model: "server-model", Protocol: "chat", Level: "primary"}}, Client: &http.Client{Transport: processingTransport(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"choices":[{"message":{"content":"draft"}}]}`))}, nil
	})}})
	request := processing.AIRequest{ID: importPlan, System: "contract", User: "text"}
	for i := 0; i < 2; i++ {
		result, err := s.Analyze(f.ctx, importFamily, importUser, request)
		if err != nil || result.Content != "draft" {
			t.Fatal("analyze", result, err)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("repeated inference", calls.Load())
	}
	request.User = "different"
	if _, err := s.Analyze(f.ctx, importFamily, importUser, request); !errors.Is(err, processing.ErrConflict) {
		t.Fatal("request id reused", err)
	}
	// Crash/unknown outcomes are not automatically charged again.
	f.exec(t, `UPDATE processing_ai_results SET status='running',result=NULL WHERE id=$1::uuid`, importPlan)
	request.User = "text"
	if _, err := s.Analyze(f.ctx, importFamily, importUser, request); !errors.Is(err, processing.ErrUnavailable) {
		t.Fatal("unknown outcome retried", err)
	}
	if calls.Load() != 1 {
		t.Fatal("unknown outcome charged again")
	}
}
func TestPostgresHistoryCursorWaitsForEarlierCommit(t *testing.T) {
	f := newImportPostgresFixture(t)
	// The statement trigger locks before identity allocation. Verify it blocks
	// another writer even if the first transaction subsequently rolls back.
	tx, err := f.db.BeginTx(f.ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(f.ctx, `INSERT INTO consumption_records(family_id) SELECT id FROM families WHERE false`); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(f.ctx, 100*time.Millisecond)
	defer cancel()
	_, err = f.db.ExecContext(ctx, `INSERT INTO consumption_records(family_id) SELECT id FROM families WHERE false`)
	if err == nil {
		t.Fatal("second history writer passed ordering lock")
	}
}

func TestPostgresExistingOCRAndDraftAssociationMigrateWithoutReprocessing(t *testing.T) {
	f := newImportPostgresFixture(t)
	s := processing.New(f.db, processing.AIConfig{})
	u := processing.Upload{ID: importPlan, EntityType: "intake_draft", EntityID: importCategory, MediaType: "instruction_image", Content: processingImage(t), OCRText: "原本机 OCR 文本"}
	a, err := s.Upload(f.ctx, importFamily, importUser, u)
	if err != nil || a.OCRStatus != "complete" || a.OCRText != u.OCRText {
		t.Fatalf("legacy OCR not migrated: %#v %v", a, err)
	}
	s.OCR = func(context.Context, []byte) (string, error) { t.Fatal("migration repeated OCR"); return "", nil }
	if _, err := s.RunOCR(f.ctx, importFamily, u.ID); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := s.Reassign(f.ctx, importFamily, u.ID, importProduct); err != nil {
			t.Fatal(err)
		}
	}
	listed, err := s.List(f.ctx, importFamily, "product", importProduct, "")
	if err != nil || len(listed) != 1 || listed[0].OCRText != u.OCRText {
		t.Fatal("association lost OCR", listed, err)
	}
	sources, searchErr := s.SearchManual(f.ctx, importFamily, importProduct, "如何找到原本机文字？")
	if searchErr != nil || len(sources) != 1 || sources[0].AssetID != u.ID {
		t.Fatalf("manual retrieval failed: %#v %v", sources, searchErr)
	}
	old, err := s.List(f.ctx, importFamily, "intake_draft", importCategory, "")
	if err != nil || len(old) != 0 {
		t.Fatal("old association still exposed", old, err)
	}
}
