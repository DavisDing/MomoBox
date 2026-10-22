package syncpostgres

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	syncdomain "github.com/momobox/backend/internal/sync"
)

const importUser = "a0000000-0000-4000-8000-000000000001"
const importFamily = "a0000000-0000-4000-8000-000000000002"
const importDevice = "a0000000-0000-4000-8000-000000000003"
const importSecondDevice = "a0000000-0000-4000-8000-000000000004"
const importPlan = "a0000000-0000-4000-8000-000000000005"
const importProduct = "a0000000-0000-4000-8000-000000000006"
const importBatch = "a0000000-0000-4000-8000-000000000007"
const importCategory = "a0000000-0000-4000-8000-000000000008"

type importPostgresFixture struct {
	ctx     context.Context
	db      *sql.DB
	service *syncdomain.Service
	actor   syncdomain.DeviceScope
}

// This suite never uses the application DSN or a localhost fallback. All
// business objects/functions live in a generated schema with no public path.
func newImportPostgresFixture(t *testing.T) *importPostgresFixture {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL"))
	if dsn == "" {
		t.Skip("MOMO_TEST_DATABASE_URL is unset; real import PostgreSQL validation not executed")
	}
	var entropy [10]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	schema := "momobox_import_test_" + hex.EncodeToString(entropy[:])
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid explicit PostgreSQL test configuration")
	}
	if config.RuntimeParams == nil {
		config.RuntimeParams = map[string]string{}
	}
	config.RuntimeParams["search_path"] = schema
	config.RuntimeParams["timezone"] = "UTC"
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	t.Cleanup(cancel)
	db := stdlib.OpenDB(*config)
	db.SetMaxOpenConns(4)
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.ExecContext(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal("create isolated import test schema:", err)
	}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := db.ExecContext(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error("clean up isolated import schema:", err)
		}
	})
	files, err := filepath.Glob("../../../migrations/*.sql")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range files {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		migration := strings.ReplaceAll(string(raw), "SET LOCAL search_path = public;", "SET LOCAL search_path = "+schema+";")
		migration = strings.ReplaceAll(migration, "'public.change_log'", "'"+schema+".change_log'")
		// gen_random_uuid is built into PostgreSQL 16/18. Installing a shared
		// extension would escape this test schema, so skip that bootstrap line.
		migration = strings.ReplaceAll(migration, "CREATE EXTENSION IF NOT EXISTS pgcrypto;", "")
		if strings.Contains(initialQuantityMigrationSQL(migration), "public") {
			t.Fatal("migration retained a public schema reference")
		}
		if _, err := db.ExecContext(ctx, migration); err != nil {
			t.Fatalf("isolated migration %s: %v", filepath.Base(path), err)
		}
	}
	f := &importPostgresFixture{
		ctx: ctx, db: db, service: syncdomain.NewService(New(db)),
		actor: syncdomain.DeviceScope{DeviceID: importDevice, UserID: importUser, FamilyID: importFamily},
	}
	f.exec(t, `INSERT INTO users(id,email,password_hash,nickname) VALUES($1::uuid,'import@example.test','fixture','importer')`, importUser)
	f.exec(t, `INSERT INTO families(id,name,created_by_user_id) VALUES($1::uuid,'Home',$2::uuid)`, importFamily, importUser)
	f.exec(t, `INSERT INTO family_members(family_id,user_id,role) VALUES($1::uuid,$2::uuid,'owner')`, importFamily, importUser)
	f.exec(t, `UPDATE users SET current_family_id=$2::uuid WHERE id=$1::uuid`, importUser, importFamily)
	for _, device := range []string{importDevice, importSecondDevice} {
		f.exec(t, `INSERT INTO sync_devices(id,family_id,user_id,device_name,platform) VALUES($1::uuid,$2::uuid,$3::uuid,'test phone','other')`, device, importFamily, importUser)
		f.exec(t, `INSERT INTO sync_bootstrap_checkpoints(family_id,device_id,local_workspace_id,mode,state) VALUES($1::uuid,$2::uuid,'source-workspace','join_and_merge','confirmed')`, importFamily, device)
	}
	return f
}

func (f *importPostgresFixture) exec(t *testing.T, query string, args ...any) {
	t.Helper()
	if _, err := f.db.ExecContext(f.ctx, query, args...); err != nil {
		t.Fatal(err)
	}
}

func (f *importPostgresFixture) count(t *testing.T, table string) int {
	t.Helper()
	allowed := map[string]bool{
		"products": true, "product_batches": true, "change_log": true,
		"imported_stock_history": true, "consumption_records": true, "sync_import_plans": true,
	}
	if !allowed[table] {
		t.Fatal("unsafe test table")
	}
	var value int
	if err := f.db.QueryRowContext(f.ctx, "SELECT count(*) FROM "+table).Scan(&value); err != nil {
		t.Fatal(err)
	}
	return value
}

func importManifest() syncdomain.ImportRequest {
	return syncdomain.ImportRequest{
		FormatVersion: 1, DeviceID: importDevice, ImportID: importPlan, LocalWorkspaceID: "source-workspace",
		Categories: []map[string]any{{"id": importCategory, "name": "Food"}},
		Products: []map[string]any{{
			"id": importProduct, "name": "Milk", "category_id": importCategory,
			"location": "Pantry", "unit": "件", "low_stock_threshold": 2, "created_at": "2020-01-01T00:00:00Z",
		}},
		ProductBatches: []map[string]any{{
			"id": importBatch, "product_id": importProduct, "initial_quantity": 12,
			"quantity": 5, "status": "active", "batch_no": "original-12", "is_opened": true,
			"produced_date": "2020-01-01", "expiry_date": "2026-10-22",
		}},
		ShoppingItems: []map[string]any{{
			"id": "b0000000-0000-4000-8000-000000000001", "name": "Milk", "category": "Food",
			"reason": "low stock", "desired_quantity": 2, "checked": true,
		}},
		ReminderSettings: []map[string]any{{
			"id": "b0000000-0000-4000-8000-000000000002", "product_id": importProduct, "low_stock_threshold": 2,
		}},
		History: []map[string]any{
			{
				"id": "c0000000-0000-4000-8000-000000000001", "product_id": importProduct,
				"batch_id": importBatch, "type": "intake", "quantity": 12, "occurred_at": "2020-01-01T08:00:00+08:00",
			},
			{
				"id": "c0000000-0000-4000-8000-000000000002", "product_id": importProduct,
				"batch_id": nil, "type": "consume", "quantity": -7, "note": "original history",
				"occurred_at": "2020-01-02T08:00:00+08:00",
			},
		},
	}
}

func (f *importPostgresFixture) prepare(t *testing.T, manifest syncdomain.ImportRequest) syncdomain.ImportReceipt {
	t.Helper()
	receipt, err := f.service.PreflightImport(f.ctx, f.actor, manifest)
	if err != nil || !receipt.Ready || receipt.Status != "prepared" {
		t.Fatalf("preflight: %+v err=%v", receipt, err)
	}
	return receipt
}

func confirmRequest(receipt syncdomain.ImportReceipt) syncdomain.ImportConfirmRequest {
	return syncdomain.ImportConfirmRequest{DeviceID: importDevice, Checkpoint: receipt.Checkpoint, Fingerprint: receipt.Fingerprint}
}

func TestPostgresInitialImportBaselineHistoryReplayAndNewDevice(t *testing.T) {
	f := newImportPostgresFixture(t)
	manifest := importManifest()
	prepared := f.prepare(t, manifest)
	if f.count(t, "products") != 0 || f.count(t, "imported_stock_history") != 0 {
		t.Fatal("preflight wrote business data")
	}
	completed, err := f.service.ConfirmImport(f.ctx, f.actor, manifest.ImportID, confirmRequest(prepared))
	if err != nil || completed.Status != "completed" || completed.Ready {
		t.Fatalf("confirm=%+v err=%v", completed, err)
	}
	var initial, current int
	var opened bool
	var batchNo, expiry string
	if err := f.db.QueryRowContext(f.ctx, `SELECT initial_quantity,quantity,is_opened,batch_no,expiry_date::text FROM product_batches WHERE id=$1::uuid`, importBatch).Scan(&initial, &current, &opened, &batchNo, &expiry); err != nil {
		t.Fatal(err)
	}
	if initial != 12 || current != 5 || !opened || batchNo != "original-12" || expiry != "2026-10-22" {
		t.Fatal("baseline quantity, fields or calendar date changed")
	}
	var location, unit, created string
	var threshold int
	if err := f.db.QueryRowContext(f.ctx, `SELECT location,unit,low_stock_threshold,created_at::text FROM products WHERE id=$1::uuid`, importProduct).Scan(&location, &unit, &threshold, &created); err != nil {
		t.Fatal(err)
	}
	if location != "Pantry" || unit != "件" || threshold != 2 || !strings.HasPrefix(created, "2020-01-01") {
		t.Fatal("product import lost original fields")
	}
	if f.count(t, "consumption_records") != 0 || f.count(t, "imported_stock_history") != 2 || f.count(t, "change_log") != 5 {
		t.Fatal("baseline fabricated inventory commands or lost archive/change rows")
	}
	// Response loss and same-account second-phone retries return one durable
	// receipt, independent of expiring device request-id caches.
	second := f.actor
	second.DeviceID = importSecondDevice
	confirmation := confirmRequest(prepared)
	confirmation.DeviceID = importSecondDevice
	replay, err := f.service.ConfirmImport(f.ctx, second, manifest.ImportID, confirmation)
	if err != nil || replay.ServerCursor != completed.ServerCursor || f.count(t, "change_log") != 5 {
		t.Fatalf("replay changed baseline: %+v %v", replay, err)
	}
	manifest.DeviceID = importSecondDevice
	replay, err = f.service.PreflightImport(f.ctx, second, manifest)
	if err != nil || replay.Status != "completed" {
		t.Fatalf("manifest retry=%+v err=%v", replay, err)
	}
	manifest.ImportID = "d0000000-0000-4000-8000-000000000001"
	blocked, err := f.service.PreflightImport(f.ctx, second, manifest)
	if err != nil || blocked.Ready || len(blocked.Blockers) == 0 || f.count(t, "sync_import_plans") != 1 {
		t.Fatalf("second plan duplicated state: %+v err=%v", blocked, err)
	}
	page, err := f.service.ImportHistory(f.ctx, second, syncdomain.ImportHistoryRequest{Limit: 1})
	if err != nil || len(page.Records) != 1 || !page.HasMore {
		t.Fatalf("first archive page=%+v err=%v", page, err)
	}
	last, err := f.service.ImportHistory(f.ctx, second, syncdomain.ImportHistoryRequest{After: page.NextCursor, Until: page.Until, Limit: 1})
	if err != nil || len(last.Records) != 1 || last.HasMore || last.NextCursor != page.Until {
		t.Fatalf("last archive page=%+v err=%v", last, err)
	}
	if f.count(t, "consumption_records") != 0 {
		t.Fatal("history replay generated consumption records")
	}
}

func TestPostgresInitialImportRollbackAndStableRetry(t *testing.T) {
	for _, deferred := range []bool{false, true} {
		t.Run(map[bool]string{false: "receipt write failure", true: "commit failure"}[deferred], func(t *testing.T) {
			f := newImportPostgresFixture(t)
			manifest := importManifest()
			prepared := f.prepare(t, manifest)
			f.exec(t, `CREATE FUNCTION import_fail_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.state='completed' THEN RAISE EXCEPTION 'injected receipt failure'; END IF; RETURN NEW; END; $$`)
			trigger := `CREATE TRIGGER import_fail BEFORE UPDATE ON sync_import_plans FOR EACH ROW EXECUTE FUNCTION import_fail_receipt()`
			if deferred {
				trigger = `CREATE CONSTRAINT TRIGGER import_fail AFTER UPDATE ON sync_import_plans DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION import_fail_receipt()`
			}
			f.exec(t, trigger)
			if _, err := f.service.ConfirmImport(f.ctx, f.actor, manifest.ImportID, confirmRequest(prepared)); err == nil {
				t.Fatal("injected failure accepted")
			}
			for _, table := range []string{"products", "product_batches", "change_log", "imported_stock_history", "consumption_records"} {
				if f.count(t, table) != 0 {
					t.Fatalf("partial transaction survived in %s", table)
				}
			}
			saved, err := f.service.ImportReceipt(f.ctx, f.actor, manifest.ImportID)
			if err != nil || saved.Status != "prepared" || saved.Checkpoint != prepared.Checkpoint {
				t.Fatalf("failed transaction lost original prepared receipt: %+v %v", saved, err)
			}
			f.exec(t, `DROP TRIGGER import_fail ON sync_import_plans`)
			if _, err := f.service.ConfirmImport(f.ctx, f.actor, manifest.ImportID, confirmRequest(prepared)); err != nil {
				t.Fatal("stable retry failed:", err)
			}
		})
	}
}

func TestPostgresInitialImportConcurrentConfirmAndRevocation(t *testing.T) {
	f := newImportPostgresFixture(t)
	manifest := importManifest()
	prepared := f.prepare(t, manifest)
	var wait sync.WaitGroup
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, err := f.service.ConfirmImport(f.ctx, f.actor, manifest.ImportID, confirmRequest(prepared))
			errs <- err
		}()
	}
	wait.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if f.count(t, "products") != 1 || f.count(t, "imported_stock_history") != 2 || f.count(t, "change_log") != 5 {
		t.Fatal("concurrent confirms duplicated baseline")
	}
	f.exec(t, `UPDATE sync_devices SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1::uuid`, importDevice)
	if _, err := f.service.ImportReceipt(f.ctx, f.actor, manifest.ImportID); err == nil {
		t.Fatal("revoked device read import receipt")
	}
	// Retained receipts must not prevent the existing soft-delete revocation.
	f.exec(t, `UPDATE family_members SET deleted_at=CURRENT_TIMESTAMP WHERE family_id=$1::uuid AND user_id=$2::uuid`, importFamily, importUser)
}

func TestPostgresInitialImportRejectsChangedManifestAndTargets(t *testing.T) {
	f := newImportPostgresFixture(t)
	manifest := importManifest()
	prepared := f.prepare(t, manifest)
	manifest.Products[0]["name"] = "changed"
	_, err := f.service.PreflightImport(f.ctx, f.actor, manifest)
	var business *syncdomain.BusinessError
	if !errors.As(err, &business) || business.Code != "IMPORT_ID_REUSED" {
		t.Fatalf("changed manifest error=%v", err)
	}
	manifest = importManifest()
	f.exec(t, `INSERT INTO products(id,family_id,name) VALUES($1::uuid,$2::uuid,'concurrent product')`, importProduct, importFamily)
	if _, err := f.service.ConfirmImport(f.ctx, f.actor, manifest.ImportID, confirmRequest(prepared)); err == nil {
		t.Fatal("target overlap after preflight was overwritten")
	}
	blocked, err := f.service.PreflightImport(f.ctx, f.actor, manifest)
	if err != nil || blocked.Ready || len(blocked.Blockers) == 0 {
		t.Fatalf("overlap preflight=%+v err=%v", blocked, err)
	}
	if _, err := f.service.ImportReceipt(f.ctx, f.actor, manifest.ImportID); !errors.Is(err, syncdomain.ErrNotFound) {
		t.Fatalf("blocked preflight left confirmable plan: %v", err)
	}
	if f.count(t, "products") != 1 || f.count(t, "product_batches") != 0 || f.count(t, "imported_stock_history") != 0 {
		t.Fatal("blocked import modified business state")
	}
}

// Use pgx's production default extended protocol, rather than a permissive SQL
// fake. Both insertion and update must bind exactly the placeholders they use.
func TestPostgresOrdinaryEntityWritesUseContiguousTypedParameters(t *testing.T) {
	f := newImportPostgresFixture(t)
	tx, err := f.db.BeginTx(f.ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	adapter := &transactionRepository{tx: tx, familyID: importFamily, deviceID: importDevice, userID: importUser}
	inserted, err := adapter.UpsertEntity(f.ctx, syncdomain.EntityMutation{
		Entity: "products", EntityID: importProduct,
		Payload: map[string]any{"name": "Milk"},
	})
	if err != nil {
		t.Fatal("ordinary insert:", err)
	}
	updated, err := adapter.UpsertEntity(f.ctx, syncdomain.EntityMutation{
		Entity: "products", EntityID: importProduct, BaseVersion: inserted.Version,
		Payload: map[string]any{"name": "Updated milk"},
	})
	if err != nil {
		t.Fatal("ordinary update:", err)
	}
	if updated.Version != 2 || updated.Payload["name"] != "Updated milk" || updated.Payload["created_by_user_id"] != importUser {
		t.Fatalf("ordinary write metadata/version changed: %+v", updated)
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
}
