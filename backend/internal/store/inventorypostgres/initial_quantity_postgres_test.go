package inventorypostgres

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/momobox/backend/internal/inventory"
)

const (
	initialQuantityFamilyID  = "10000000-0000-4000-8000-000000000001"
	initialQuantityProductID = "20000000-0000-4000-8000-000000000001"
	initialQuantityBatchID   = "30000000-0000-4000-8000-000000000001"
	initialQuantityActorID   = "40000000-0000-4000-8000-000000000001"
	initialQuantityDeviceID  = "50000000-0000-4000-8000-000000000001"
)

// These are opt-in repository/service integration tests, not migration tests.
// The fixture includes only the tables/constraints needed by actual inventory
// SQL; family membership, sync bootstrap and migration backfill are out of scope.
// Every connection uses an isolated search_path with no public fallback.
func newInitialQuantityPostgres(t *testing.T) (context.Context, *sql.DB) {
	t.Helper()
	url := strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL"))
	if url == "" {
		t.Skip("MOMO_TEST_DATABASE_URL is unset; real PostgreSQL quantity validation not executed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	config, err := pgx.ParseConfig(url)
	if err != nil {
		// Do not print the supplied DSN (which may contain credentials).
		t.Fatal("parse MOMO_TEST_DATABASE_URL: invalid PostgreSQL connection configuration")
	}
	admin := stdlib.OpenDB(*config)
	t.Cleanup(func() { _ = admin.Close() })
	if err := admin.PingContext(ctx); err != nil {
		t.Fatalf("connect to explicit test database: %v", err)
	}
	var entropy [12]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	// Only a generated lowercase/hex identifier is interpolated into DDL.
	schema := "momobox_initial_quantity_test_" + hex.EncodeToString(entropy[:])
	if _, err := admin.ExecContext(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatalf("create isolated quantity schema: %v", err)
	}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := admin.ExecContext(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Errorf("clean up isolated quantity schema: %v", err)
		}
	})
	scoped := config.Copy()
	if scoped.RuntimeParams == nil {
		scoped.RuntimeParams = make(map[string]string)
	}
	scoped.RuntimeParams["search_path"] = schema
	db := stdlib.OpenDB(*scoped)
	db.SetMaxOpenConns(3)
	t.Cleanup(func() { _ = db.Close() })
	if err := db.PingContext(ctx); err != nil {
		t.Fatalf("connect to isolated quantity schema: %v", err)
	}
	if _, err := db.ExecContext(ctx, `
CREATE TABLE product_batches (
    id uuid PRIMARY KEY,
    family_id uuid NOT NULL,
    product_id uuid NOT NULL,
    expiry_date date,
    quantity integer NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    initial_quantity integer NOT NULL DEFAULT 0 CHECK (initial_quantity >= 0),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'used_up', 'expired', 'discarded')),
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamptz,
    UNIQUE (id, family_id)
);
CREATE TABLE consumption_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id uuid NOT NULL,
    batch_id uuid NOT NULL,
    product_id uuid NOT NULL,
    record_type text NOT NULL CHECK (record_type IN ('consume', 'restock', 'discard', 'adjust')),
    quantity_change integer NOT NULL CHECK (
        (record_type IN ('consume', 'discard') AND quantity_change < 0)
        OR (record_type = 'restock' AND quantity_change > 0)
        OR (record_type = 'adjust' AND quantity_change <> 0)
    ),
    reason text,
    operation_id uuid,
    idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 16 AND 255),
    created_by_user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (batch_id, family_id) REFERENCES product_batches (id, family_id),
    UNIQUE (family_id, device_id, idempotency_key)
);
CREATE TABLE change_log (
    cursor bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_id uuid NOT NULL UNIQUE,
    family_id uuid NOT NULL,
    operation text NOT NULL,
    entity text NOT NULL,
    entity_id uuid NOT NULL,
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    updated_by_device uuid
);
CREATE TABLE sync_idempotency (
    idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 16 AND 255),
    family_id uuid NOT NULL,
    device_id uuid NOT NULL,
    operation text NOT NULL,
    entity text,
    status text NOT NULL CHECK (status IN ('processing', 'accepted', 'conflict', 'rejected')),
    response_payload jsonb NOT NULL CHECK (jsonb_typeof(response_payload) = 'object'),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamptz,
    expires_at timestamptz,
    PRIMARY KEY (family_id, device_id, idempotency_key)
);`); err != nil {
		t.Fatalf("create isolated inventory fixture: %v", err)
	}
	return ctx, db
}

func seedInitialQuantityBatch(t *testing.T, ctx context.Context, db *sql.DB, quantity, initial int) {
	t.Helper()
	if _, err := db.ExecContext(ctx, `
INSERT INTO product_batches (id, family_id, product_id, quantity, initial_quantity)
VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5)`,
		initialQuantityBatchID, initialQuantityFamilyID, initialQuantityProductID, quantity, initial); err != nil {
		t.Fatalf("seed quantity batch: %v", err)
	}
}

type initialQuantityBatchState struct {
	quantity int
	initial  int
	version  int64
	status   string
}

func assertInitialQuantityBatch(t *testing.T, ctx context.Context, db *sql.DB, want initialQuantityBatchState) {
	t.Helper()
	var got initialQuantityBatchState
	if err := db.QueryRowContext(ctx, `
SELECT quantity, initial_quantity, version, status FROM product_batches
WHERE family_id = $1::uuid AND id = $2::uuid`, initialQuantityFamilyID, initialQuantityBatchID).
		Scan(&got.quantity, &got.initial, &got.version, &got.status); err != nil {
		t.Fatalf("read committed batch state: %v", err)
	}
	if got != want {
		t.Fatalf("committed batch = %+v; want %+v", got, want)
	}
}

func assertInitialQuantityWrites(t *testing.T, ctx context.Context, db *sql.DB, want int) {
	t.Helper()
	for _, table := range []string{"consumption_records", "change_log", "sync_idempotency"} {
		var got int
		if err := db.QueryRowContext(ctx, "SELECT count(*) FROM "+table).Scan(&got); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		if got != want {
			t.Fatalf("%s has %d rows; want %d (no duplicated/partially committed writes)", table, got, want)
		}
	}
}

// Verify actual persisted audit and replay payloads, not only row counts.
func assertInitialQuantityReceipt(t *testing.T, ctx context.Context, db *sql.DB, command inventory.Command, want inventory.Result) {
	t.Helper()
	var changePayload, receiptPayload []byte
	if err := db.QueryRowContext(ctx, `
SELECT payload FROM change_log
WHERE change_id = $1::uuid AND family_id = $2::uuid AND entity_id = $3::uuid
  AND operation = 'inventory_command' AND entity = 'product_batches'
  AND updated_by_device = $4::uuid`,
		command.OperationID, command.FamilyID, command.BatchID, command.DeviceID).Scan(&changePayload); err != nil {
		t.Fatalf("read canonical inventory change: %v", err)
	}
	var change inventory.Result
	if err := json.Unmarshal(changePayload, &change); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(change, want) {
		t.Fatalf("persisted inventory change = %+v; want %+v", change, want)
	}
	if err := db.QueryRowContext(ctx, `
SELECT response_payload FROM sync_idempotency
WHERE family_id = $1::uuid AND device_id = $2::uuid AND idempotency_key = $3
  AND operation = 'inventory_command' AND entity = 'product_batches'
  AND status = 'accepted' AND completed_at IS NOT NULL`,
		command.FamilyID, command.DeviceID, command.IdempotencyKey).Scan(&receiptPayload); err != nil {
		t.Fatalf("read accepted inventory receipt: %v", err)
	}
	var envelope struct {
		Result inventory.Result `json:"inventory_result"`
	}
	if err := json.Unmarshal(receiptPayload, &envelope); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(envelope.Result, want) {
		t.Fatalf("persisted idempotency receipt = %+v; want %+v", envelope.Result, want)
	}
}

func initialQuantityCommand(sequence int, name inventory.CommandName, quantity int) inventory.Command {
	operationID := fmt.Sprintf("60000000-0000-4000-8000-%012d", sequence)
	return inventory.Command{
		FamilyID: initialQuantityFamilyID, ActorID: initialQuantityActorID, DeviceID: initialQuantityDeviceID,
		OperationID: operationID, IdempotencyKey: "initial-quantity-test:" + operationID,
		ProductID: initialQuantityProductID, BatchID: initialQuantityBatchID, Quantity: quantity, Command: name,
	}
}

func TestPostgresInitialQuantityServiceRestockReplayAndDepletion(t *testing.T) {
	ctx, db := newInitialQuantityPostgres(t)
	// Match the new-batch path: quantity and initial_quantity begin at the SQL
	// defaults, and real restock commands (not entity upserts) add the stock.
	if _, err := db.ExecContext(ctx, `
INSERT INTO product_batches (id, family_id, product_id) VALUES ($1::uuid, $2::uuid, $3::uuid)`,
		initialQuantityBatchID, initialQuantityFamilyID, initialQuantityProductID); err != nil {
		t.Fatal(err)
	}
	service := inventory.NewService(New(db))
	steps := []struct {
		name       string
		command    inventory.CommandName
		amount     int
		recordType string
		delta      int
		want       initialQuantityBatchState
	}{
		{"first restock", inventory.CommandRestock, 5, "restock", 5, initialQuantityBatchState{5, 5, 2, "active"}},
		{"second restock", inventory.CommandRestock, 2, "restock", 2, initialQuantityBatchState{7, 7, 3, "active"}},
		{"partial consume", inventory.CommandConsumeFEFO, 4, "consume", -4, initialQuantityBatchState{3, 7, 4, "active"}},
		{"consume to zero", inventory.CommandConsumeFEFO, 3, "consume", -3, initialQuantityBatchState{0, 7, 5, "used_up"}},
		{"restock used up batch", inventory.CommandRestock, 4, "restock", 4, initialQuantityBatchState{4, 11, 6, "active"}},
		{"discard remaining", inventory.CommandDiscard, 4, "discard", -4, initialQuantityBatchState{0, 11, 7, "discarded"}},
	}
	for index, step := range steps {
		t.Run(step.name, func(t *testing.T) {
			command := initialQuantityCommand(index+1, step.command, step.amount)
			result, err := service.Execute(ctx, command)
			if err != nil {
				t.Fatalf("execute actual service: %v", err)
			}
			wantResult := inventory.Result{
				OperationID: command.OperationID, Command: command.Command,
				Allocations: []inventory.Allocation{{
					BatchID: initialQuantityBatchID, Quantity: step.amount,
					BeforeQuantity: step.want.quantity - step.delta, FinalQuantity: step.want.quantity,
					BeforeVersion: step.want.version - 1, AfterVersion: step.want.version,
				}},
			}
			if !reflect.DeepEqual(result, wantResult) {
				t.Fatalf("service receipt = %+v; want %+v", result, wantResult)
			}
			assertInitialQuantityBatch(t, ctx, db, step.want)
			assertInitialQuantityWrites(t, ctx, db, index+1)
			assertInitialQuantityReceipt(t, ctx, db, command, wantResult)
			var recordType string
			var delta int
			if err := db.QueryRowContext(ctx, `
SELECT record_type, quantity_change FROM consumption_records
WHERE operation_id = $1::uuid AND family_id = $2::uuid AND batch_id = $3::uuid`,
				command.OperationID, command.FamilyID, command.BatchID).Scan(&recordType, &delta); err != nil {
				t.Fatal(err)
			}
			if recordType != step.recordType || delta != step.delta {
				t.Fatalf("history = %s/%d; want %s/%d", recordType, delta, step.recordType, step.delta)
			}
			// Replays pass through the real advisory lock and persisted receipt,
			// including commands whose batch is no longer usable after execution.
			for replay := 0; replay < 2; replay++ {
				got, err := service.Execute(ctx, command)
				if err != nil {
					t.Fatalf("replay %d: %v", replay+1, err)
				}
				wantResult.Replayed = true
				if !reflect.DeepEqual(got, wantResult) {
					t.Fatalf("replayed receipt = %+v; want %+v", got, wantResult)
				}
				assertInitialQuantityBatch(t, ctx, db, step.want)
				assertInitialQuantityWrites(t, ctx, db, index+1)
				original := wantResult
				original.Replayed = false
				assertInitialQuantityReceipt(t, ctx, db, command, original)
			}
		})
		if t.Failed() {
			return // Later lifecycle steps depend on the previous committed state.
		}
	}
	// A delayed replay after depletion must still return the original receipt,
	// not attempt to restock the discarded batch or duplicate its history.
	result, err := service.Execute(ctx, initialQuantityCommand(1, inventory.CommandRestock, 5))
	if err != nil || !result.Replayed || len(result.Allocations) != 1 || result.Allocations[0].FinalQuantity != 5 {
		t.Fatalf("delayed first-restock replay = %+v, %v", result, err)
	}
	assertInitialQuantityBatch(t, ctx, db, steps[len(steps)-1].want)
	assertInitialQuantityWrites(t, ctx, db, len(steps))
}

func TestPostgresInitialQuantityBoundStoreActualBatchChanges(t *testing.T) {
	if strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL")) == "" {
		t.Skip("MOMO_TEST_DATABASE_URL is unset; real PostgreSQL quantity validation not executed")
	}
	cases := []struct {
		name     string
		quantity int
		initial  int
		delta    int
		discard  bool
		wantErr  error
		want     initialQuantityBatchState
	}{
		{"new restock", 0, 0, 4, false, nil, initialQuantityBatchState{4, 4, 2, "active"}},
		{"legacy initial below stock", 5, 0, 2, false, nil, initialQuantityBatchState{7, 7, 2, "active"}},
		{"legacy initial repaired before consume", 5, 0, -2, false, nil, initialQuantityBatchState{3, 5, 2, "active"}},
		{"restock adds to historical initial", 3, 10, 2, false, nil, initialQuantityBatchState{5, 12, 2, "active"}},
		{"consume preserves historical initial", 3, 10, -3, false, nil, initialQuantityBatchState{0, 10, 2, "used_up"}},
		{"restock zero stock preserves history", 0, 10, 2, false, nil, initialQuantityBatchState{2, 12, 2, "active"}},
		{"discard preserves historical initial", 4, 8, -4, true, nil, initialQuantityBatchState{0, 8, 2, "discarded"}},
		{"insufficient stock makes no repair", 5, 0, -6, false, inventory.ErrInsufficientStock, initialQuantityBatchState{5, 0, 1, "active"}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			ctx, db := newInitialQuantityPostgres(t)
			seedInitialQuantityBatch(t, ctx, db, test.quantity, test.initial)
			tx, err := db.BeginTx(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback() }()
			err = BindTransaction(tx, true).RunInTransaction(ctx, func(ctx context.Context, repo inventory.Tx) error {
				batch, err := repo.FindBatchForUpdate(ctx, initialQuantityFamilyID, initialQuantityBatchID)
				if err != nil {
					return err
				}
				if batch.Quantity != test.quantity || batch.Version != 1 {
					return fmt.Errorf("locked pre-state = %+v", batch)
				}
				change := inventory.BatchChange{BatchID: batch.ID, QuantityDelta: test.delta}
				if test.discard {
					status := inventory.BatchDiscarded
					change.NewStatus = &status
				}
				return repo.ApplyBatchChanges(ctx, []inventory.BatchChange{change})
			})
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("actual batch change error = %v; want %v", err, test.wantErr)
			}
			// BoundStore does not own commit/rollback; the outer transaction must.
			if err != nil {
				err = tx.Rollback()
			} else {
				err = tx.Commit()
			}
			if err != nil {
				t.Fatal(err)
			}
			assertInitialQuantityBatch(t, ctx, db, test.want)
			assertInitialQuantityWrites(t, ctx, db, 0)
		})
	}
}

func TestPostgresInitialQuantityServiceFailureRollsBackAllWrites(t *testing.T) {
	if strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL")) == "" {
		t.Skip("MOMO_TEST_DATABASE_URL is unset; real PostgreSQL quantity validation not executed")
	}
	cases := []struct {
		name     string
		table    string
		deferred bool
		stage    string
	}{
		{"history insert", "consumption_records", false, "append consumption record"},
		{"change log insert", "change_log", false, "append inventory change"},
		{"receipt insert", "sync_idempotency", false, "save inventory idempotency result"},
		{"commit failure", "sync_idempotency", true, "commit inventory transaction"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			ctx, db := newInitialQuantityPostgres(t)
			seedInitialQuantityBatch(t, ctx, db, 0, 0)
			if _, err := db.ExecContext(ctx, `
CREATE FUNCTION initial_quantity_fail_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'injected initial quantity write failure' USING ERRCODE = 'P0001';
END;
$$;`); err != nil {
				t.Fatal(err)
			}
			trigger := "CREATE TRIGGER initial_quantity_fail BEFORE INSERT ON " + test.table +
				" FOR EACH ROW EXECUTE FUNCTION initial_quantity_fail_write()"
			if test.deferred {
				// All SQL writes succeed first; this trigger fails only at commit.
				trigger = "CREATE CONSTRAINT TRIGGER initial_quantity_fail AFTER INSERT ON " + test.table +
					" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION initial_quantity_fail_write()"
			}
			if _, err := db.ExecContext(ctx, trigger); err != nil {
				t.Fatal(err)
			}
			service := inventory.NewService(New(db))
			command := initialQuantityCommand(1, inventory.CommandRestock, 5)
			_, err := service.Execute(ctx, command)
			var pgErr *pgconn.PgError
			if !errors.As(err, &pgErr) || pgErr.Code != "P0001" ||
				pgErr.Message != "injected initial quantity write failure" || !strings.Contains(err.Error(), test.stage) {
				t.Fatalf("expected injected failure at %s, got %v", test.stage, err)
			}
			assertInitialQuantityBatch(t, ctx, db, initialQuantityBatchState{0, 0, 1, "active"})
			assertInitialQuantityWrites(t, ctx, db, 0)
			if _, err := db.ExecContext(ctx, "DROP TRIGGER initial_quantity_fail ON "+test.table); err != nil {
				t.Fatal(err)
			}
			// The failed command must not leave a successful idempotency receipt.
			result, err := service.Execute(ctx, command)
			if err != nil || result.Replayed {
				t.Fatalf("retry after rollback = %+v, %v; want newly accepted command", result, err)
			}
			assertInitialQuantityBatch(t, ctx, db, initialQuantityBatchState{5, 5, 2, "active"})
			assertInitialQuantityWrites(t, ctx, db, 1)
			result, err = service.Execute(ctx, command)
			if err != nil || !result.Replayed {
				t.Fatalf("replay after successful retry = %+v, %v", result, err)
			}
			assertInitialQuantityBatch(t, ctx, db, initialQuantityBatchState{5, 5, 2, "active"})
			assertInitialQuantityWrites(t, ctx, db, 1)
		})
	}
}
