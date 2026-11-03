package syncpostgres

import (
	"context"
	"errors"
	"github.com/momobox/backend/internal/processing"
	syncdomain "github.com/momobox/backend/internal/sync"
	"net/http"
	"testing"
	"time"
)

func TestPostgresConstraintConflictsRemainReviewable(t *testing.T) {
	for _, query := range []string{
		`INSERT INTO users(id,email,password_hash,nickname) SELECT id,email,password_hash,nickname FROM users LIMIT 1`,
		`INSERT INTO products(family_id,name) VALUES('ffffffff-ffff-ffff-ffff-ffffffffffff','missing family')`,
	} {
		f := newImportPostgresFixture(t)
		err := New(f.db).WithTransaction(f.ctx, importFamily, func(raw syncdomain.SyncTransaction) error {
			tr := raw.(*transactionRepository)
			_, err := tr.WithinChange(f.ctx, func() (syncdomain.StoredOutcome, error) {
				_, e := tr.tx.ExecContext(f.ctx, query)
				return syncdomain.StoredOutcome{}, e
			})
			var business *syncdomain.BusinessError
			if !errors.As(err, &business) || business.Code != "VERSION_CONFLICT" {
				t.Fatalf("constraint silently rejected: %v", err)
			}
			var ok int
			return tr.tx.QueryRowContext(f.ctx, `SELECT 1`).Scan(&ok)
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestPostgresClientTimeOnlyWrittenOnNewConsumptionRow(t *testing.T) {
	f := newImportPostgresFixture(t)
	f.exec(t, `INSERT INTO products(id,family_id,name) VALUES($1::uuid,$2::uuid,'item')`, importProduct, importFamily)
	f.exec(t, `INSERT INTO product_batches(id,family_id,product_id,quantity,initial_quantity) VALUES($1::uuid,$2::uuid,$3::uuid,5,5)`, importBatch, importFamily, importProduct)
	original := time.Date(2026, 11, 3, 1, 0, 0, 0, time.UTC)
	f.exec(t, `INSERT INTO consumption_records(id,family_id,batch_id,product_id,record_type,quantity_change,operation_id,idempotency_key,device_id,created_by_user_id,client_occurred_at) VALUES($1::uuid,$2::uuid,$3::uuid,$4::uuid,'consume',-1,$5::uuid,'legacy-history-key',$6::uuid,$8::uuid,$7)`, importCategory, importFamily, importBatch, importProduct, importPlan, importDevice, original, importUser)
	request := syncdomain.PushRequest{DeviceID: importDevice, Changes: []syncdomain.SyncChange{{ChangeID: importPlan, Operation: syncdomain.OperationInventoryCommand, OperationID: importPlan, Command: "restock", IdempotencyKey: "time-regression-operation", ClientUpdatedAt: "2026-11-03T05:30:00Z", Allocations: []syncdomain.InventoryAllocation{{BatchID: importBatch, Quantity: 1}}}}}
	pushed, err := f.service.Push(f.ctx, request)
	if err != nil || len(pushed.Accepted) != 1 {
		t.Fatalf("push: %#v %v", pushed, err)
	}
	var got time.Time
	if err := f.db.QueryRowContext(f.ctx, `SELECT client_occurred_at FROM consumption_records WHERE id=$1::uuid`, importCategory).Scan(&got); err != nil || !got.Equal(original) {
		t.Fatalf("historical time changed: %v %v", got, err)
	}
	if err := f.db.QueryRowContext(f.ctx, `SELECT client_occurred_at FROM consumption_records WHERE id<>$1::uuid`, importCategory).Scan(&got); err != nil || got.UTC().Hour() != 5 || got.UTC().Minute() != 30 {
		t.Fatalf("new time missing: %v %v", got, err)
	}
}

func TestPostgresAIAbandonedClaimNeverCallsProvider(t *testing.T) {
	f := newImportPostgresFixture(t)
	calls := 0
	s := processing.New(f.db, processing.AIConfig{Endpoints: []processing.AIEndpoint{{Endpoint: "http://provider.test/v1", Model: "model", Protocol: "chat"}}, Client: &http.Client{Transport: processingTransport(func(*http.Request) (*http.Response, error) { calls++; return nil, context.DeadlineExceeded })}})
	request := processing.AIRequest{ID: importPlan, User: "test"}
	_, _ = s.Analyze(f.ctx, importFamily, importUser, request)
	if calls != 1 {
		t.Fatal("provider not reached")
	}
	for _, status := range []string{"processing", "running", "failed"} {
		f.exec(t, `UPDATE processing_ai_results SET status=$1,result=NULL`, status)
		if _, err := s.Analyze(f.ctx, importFamily, importUser, request); !errors.Is(err, processing.ErrOutcomeUnknown) {
			t.Fatalf("%s did not return reviewable unknown: %v", status, err)
		}
	}
	if calls != 1 {
		t.Fatal("unknown outcome billed again")
	}
}

func TestPostgresMediaUploadRequiresProductInFamily(t *testing.T) {
	f := newImportPostgresFixture(t)
	s := processing.New(f.db, processing.AIConfig{})
	u := processing.Upload{ID: importPlan, EntityType: "product", EntityID: importProduct, MediaType: "product_image", Content: processingImage(t)}
	if _, err := s.Upload(f.ctx, importFamily, importUser, u); err == nil {
		t.Fatal("unowned product accepted")
	}
	f.exec(t, `INSERT INTO products(id,family_id,name) VALUES($1::uuid,$2::uuid,'item')`, importProduct, importFamily)
	if _, err := s.Upload(f.ctx, importFamily, importUser, u); err != nil {
		t.Fatal(err)
	}
}
