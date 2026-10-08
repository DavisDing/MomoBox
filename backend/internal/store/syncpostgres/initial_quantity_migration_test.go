package syncpostgres

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/stdlib"
)

const initialQuantityMigrationPath = "../../../migrations/0006_repair_batch_initial_quantity.sql"

func readInitialQuantityMigration(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(initialQuantityMigrationPath)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func initialQuantityMigrationSQL(raw string) string {
	// The actual migration uses line comments; ignore those for text contracts.
	var lines []string
	for _, line := range strings.Split(raw, "\n") {
		lines = append(lines, strings.SplitN(line, "--", 2)[0])
	}
	return strings.ToLower(strings.Join(strings.Fields(strings.Join(lines, "\n")), " "))
}

// This checks the migration's source contract, not real PostgreSQL behavior.
func TestInitialQuantityMigrationContract(t *testing.T) {
	migration := initialQuantityMigrationSQL(readInitialQuantityMigration(t))
	if !strings.HasPrefix(migration, "begin;") || !strings.HasSuffix(migration, "commit;") {
		t.Fatal("repair and change-log append must share an explicit transaction")
	}
	for _, required := range []string{
		"pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0))",
		"set local time zone 'utc';",
		"set local search_path = public;",
		"lock table product_batches in share row exclusive mode;",
		"select family_id, batch_id, sum(quantity_change::bigint) as stocked_quantity",
		"where record_type = 'restock' and quantity_change > 0",
		"group by family_id, batch_id",
		"greatest(b.initial_quantity::bigint, b.quantity::bigint, coalesce(r.stocked_quantity, 0))",
		"r.family_id = b.family_id and r.batch_id = b.id",
		"where b.deleted_at is null",
		"initial_quantity = bounds.repaired_initial::integer",
		"version = b.version + 1",
		"updated_at = current_timestamp",
		"b.id = bounds.id and b.family_id = bounds.family_id",
		"b.initial_quantity::bigint < bounds.repaired_initial",
		"returning b.*",
		"insert into change_log (change_id, family_id, operation, entity, entity_id, version, payload, updated_by_device)",
		"select gen_random_uuid(), family_id, 'entity_upsert', 'product_batches', id, version, to_jsonb(repaired) - 'family_id', updated_by_device from repaired",
	} {
		if !strings.Contains(migration, required) {
			t.Errorf("initial quantity repair migration missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"delete from", "truncate ", "drop table", "update consumption_records", "set quantity =",
	} {
		if strings.Contains(migration, forbidden) {
			t.Errorf("initial quantity repair must not contain %q", forbidden)
		}
	}
	lock := strings.Index(migration, "lock table product_batches")
	aggregate := strings.Index(migration, "with known_restock as")
	if lock < 0 || aggregate < 0 || lock > aggregate {
		t.Fatal("batch writers must be locked before reading historical restocks")
	}
}

type initialQuantityMigrationFixture struct {
	ctx       context.Context
	conn      *sql.Conn
	migration string
}

// Only MOMO_TEST_DATABASE_URL opts in. No application DSN or localhost fallback
// is used. All fixture work uses one pinned connection and a random schema with
// no public fallback; only the actual migration's search_path is substituted.
func newInitialQuantityMigrationFixture(t *testing.T) *initialQuantityMigrationFixture {
	t.Helper()
	url := strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL"))
	if url == "" {
		t.Skip("MOMO_TEST_DATABASE_URL is unset; real PostgreSQL migration validation not executed")
	}
	var entropy [12]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	schema := "momobox_initial_qty_migration_test_" + hex.EncodeToString(entropy[:])
	if len(schema) > 63 {
		t.Fatal("generated schema exceeds the PostgreSQL identifier limit")
	}
	raw := readInitialQuantityMigration(t)
	const searchPath = "SET LOCAL search_path = public;"
	if strings.Count(raw, searchPath) != 1 {
		t.Fatal("expected exactly one migration search_path to replace; refusing unsafe execution")
	}
	migration := strings.Replace(raw, searchPath, "SET LOCAL search_path = "+schema+";", 1)
	if regexp.MustCompile(`\bpublic\b`).MatchString(initialQuantityMigrationSQL(migration)) {
		t.Fatal("migration still references public; refusing to touch business schemas")
	}
	config, err := pgx.ParseConfig(url)
	if err != nil {
		// A parse error may contain the DSN and credentials; do not print it.
		t.Fatal("parse MOMO_TEST_DATABASE_URL: invalid PostgreSQL connection configuration")
	}
	if config.RuntimeParams == nil {
		config.RuntimeParams = make(map[string]string)
	}
	config.RuntimeParams["search_path"] = schema
	config.RuntimeParams["timezone"] = "UTC"
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	t.Cleanup(cancel)
	db := stdlib.OpenDB(*config)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	conn, err := db.Conn(ctx)
	if err != nil {
		t.Fatalf("connect to explicit migration test database: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	// The identifier contains only a fixed prefix and random lowercase hex.
	if _, err := conn.ExecContext(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatalf("create isolated migration schema: %v", err)
	}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		// Recover even if a test failed with the actual migration in an aborted
		// transaction. DROP targets only the schema successfully created above.
		if _, err := conn.ExecContext(cleanup, "ROLLBACK"); err != nil {
			t.Errorf("rollback isolated migration connection during cleanup: %v", err)
		}
		if _, err := conn.ExecContext(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Errorf("clean up isolated migration schema: %v", err)
		}
	})
	var currentSchema string
	if err := conn.QueryRowContext(ctx, "SELECT current_schema()").Scan(&currentSchema); err != nil {
		t.Fatal(err)
	}
	if currentSchema != schema {
		t.Fatal("connection is not scoped to the isolated migration schema")
	}
	fixture := &initialQuantityMigrationFixture{ctx: ctx, conn: conn, migration: migration}
	fixture.exec(t, initialQuantityMigrationTables)
	return fixture
}

// Column names, UUIDs, quantities, versions, date/timestamp and JSONB types match
// 0001. External family/product/member/device tables and their FKs are omitted.
// The history's batch FK is deliberately omitted to allow an adversarial legacy
// family mismatch: production constraints normally prevent that record, but the
// migration must independently scope its aggregate/join by family AND batch.
const initialQuantityMigrationTables = `
CREATE TABLE product_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id uuid NOT NULL,
    product_id uuid NOT NULL,
    produced_date date,
    expiry_date date,
    date_source text,
    date_precision text,
    quantity integer NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    initial_quantity integer NOT NULL DEFAULT 0 CHECK (initial_quantity >= 0),
    unit text NOT NULL DEFAULT 'piece',
    opened_date date,
    expiry_after_opening_days integer CHECK (expiry_after_opening_days >= 0),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'used_up', 'expired', 'discarded')),
    storage_location text,
    supplier text,
    price numeric(12, 2) CHECK (price >= 0),
    created_by_user_id uuid,
    updated_by_device uuid,
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
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
    UNIQUE (family_id, device_id, idempotency_key)
);
CREATE TABLE change_log (
    cursor bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    family_id uuid NOT NULL,
    operation text NOT NULL CHECK (operation IN ('entity_upsert', 'entity_delete', 'inventory_command')),
    entity text NOT NULL,
    entity_id uuid NOT NULL,
    version bigint CHECK (version IS NULL OR version >= 1),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
    updated_by_device uuid,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);`

func (f *initialQuantityMigrationFixture) exec(t *testing.T, query string, args ...any) {
	t.Helper()
	if _, err := f.conn.ExecContext(f.ctx, query, args...); err != nil {
		t.Fatalf("isolated migration fixture SQL: %v", err)
	}
}

func (f *initialQuantityMigrationFixture) migrate() error {
	_, err := f.conn.ExecContext(f.ctx, f.migration)
	if err != nil {
		// BEGIN/COMMIT belong to the actual file, not an outer sql.Tx. Explicit
		// ROLLBACK on the SAME connection is needed after a statement failure.
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, rollbackErr := f.conn.ExecContext(ctx, "ROLLBACK"); rollbackErr != nil {
			return fmt.Errorf("migration failed (%w); rollback failed: %v", err, rollbackErr)
		}
	}
	return err
}

const (
	initialQuantityMigrationFamilyA = "10000000-0000-4000-8000-000000000001"
	initialQuantityMigrationFamilyB = "10000000-0000-4000-8000-000000000002"
	initialQuantityMigrationProduct = "20000000-0000-4000-8000-000000000001"
	initialQuantityMigrationActor   = "40000000-0000-4000-8000-000000000001"
	initialQuantityMigrationDevice  = "50000000-0000-4000-8000-000000000001"
)

type initialQuantityMigrationBatch struct {
	name        string
	id          string
	family      string
	quantity    int
	initial     int
	version     int64
	deleted     bool
	restocks    []int
	wantInitial int
}

func seedInitialQuantityMigration(t *testing.T, f *initialQuantityMigrationFixture) []initialQuantityMigrationBatch {
	t.Helper()
	batches := []initialQuantityMigrationBatch{
		{"legacy zero with recorded five", "", initialQuantityMigrationFamilyA, 3, 0, 4, false, []int{5}, 5},
		{"larger historical value", "", initialQuantityMigrationFamilyA, 3, 100, 6, false, []int{5}, 100},
		{"deleted batch", "", initialQuantityMigrationFamilyA, 8, 0, 8, true, []int{15}, 0},
		{"current quantity without history", "", initialQuantityMigrationFamilyA, 3, 0, 10, false, nil, 3},
		{"sum of recorded restocks", "", initialQuantityMigrationFamilyA, 1, 0, 12, false, []int{2, 4}, 6},
		{"other family repaired independently", "", initialQuantityMigrationFamilyB, 2, 0, 14, false, []int{7}, 7},
		{"empty batch", "", initialQuantityMigrationFamilyA, 0, 0, 16, false, nil, 0},
		{"equal lower bound", "", initialQuantityMigrationFamilyA, 3, 5, 18, false, []int{5}, 5},
	}
	for i := range batches {
		batch := &batches[i]
		batch.id = fmt.Sprintf("30000000-0000-4000-8000-%012d", i+1)
		var deletedAt, device any
		device = initialQuantityMigrationDevice
		if batch.deleted {
			deletedAt = "2020-03-01T00:00:00Z"
		}
		if batch.family == initialQuantityMigrationFamilyB {
			device = nil // Nullable metadata must survive the full payload too.
		}
		f.exec(t, `
INSERT INTO product_batches (
    id, family_id, product_id, produced_date, expiry_date, date_source, date_precision,
    quantity, initial_quantity, unit, opened_date, expiry_after_opening_days, status,
    storage_location, supplier, price, created_by_user_id, updated_by_device,
    version, created_at, updated_at, deleted_at
) VALUES (
    $1::uuid, $2::uuid, $3::uuid, '2020-01-01', NULL, 'manual', 'day',
    $4, $5, 'piece', NULL, 30, 'active', 'pantry', 'fixture supplier', 12.34,
    $6::uuid, $7::uuid, $8, '2020-01-01T00:00:00Z', '2020-02-01T00:00:00Z', $9::timestamptz
)`, batch.id, batch.family, initialQuantityMigrationProduct, batch.quantity, batch.initial,
			initialQuantityMigrationActor, device, batch.version, deletedAt)
		for j, quantity := range batch.restocks {
			seedInitialQuantityMigrationRecord(t, f, batch.family, batch.id, "restock", quantity,
				fmt.Sprintf("initial-quantity-restock-%d-%d", i, j))
		}
	}
	// Non-restock positives and negative consume/discard records must not be
	// added to, or deducted from, the provable restock lower bound of five.
	for i, record := range []struct {
		kind     string
		quantity int
	}{{"adjust", 999}, {"consume", -2}, {"discard", -1}} {
		seedInitialQuantityMigrationRecord(t, f, batches[0].family, batches[0].id,
			record.kind, record.quantity, fmt.Sprintf("initial-quantity-non-restock-%d", i))
	}
	seedInitialQuantityMigrationRecord(t, f, initialQuantityMigrationFamilyB, batches[0].id,
		"restock", 500, "initial-quantity-foreign-family-poison")
	return batches
}

func seedInitialQuantityMigrationRecord(t *testing.T, f *initialQuantityMigrationFixture, family, batch, kind string, quantity int, key string) {
	t.Helper()
	f.exec(t, `
INSERT INTO consumption_records (
    family_id, batch_id, product_id, record_type, quantity_change, reason,
    operation_id, idempotency_key, created_by_user_id, device_id, created_at
) VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5, 'historical fixture',
          gen_random_uuid(), $6, $7::uuid, $8::uuid, '2020-01-15T00:00:00Z')`,
		family, batch, initialQuantityMigrationProduct, kind, quantity, key,
		initialQuantityMigrationActor, initialQuantityMigrationDevice)
}

func initialQuantityMigrationBatchJSON(t *testing.T, f *initialQuantityMigrationFixture, id string, stableOnly bool) string {
	t.Helper()
	expression := "to_jsonb(b)"
	if stableOnly {
		expression += " - 'initial_quantity' - 'version' - 'updated_at'"
	}
	var row string
	if err := f.conn.QueryRowContext(f.ctx, "SELECT ("+expression+")::text FROM product_batches AS b WHERE id = $1::uuid", id).Scan(&row); err != nil {
		t.Fatal(err)
	}
	return row
}

// Complete table snapshots catch extra/missing rows, history rewrites, timestamp
// churn and new UUIDs/cursors on a second run. Sequence allocation itself is not
// transactional in PostgreSQL, so rollback does not require gap-free cursors.
func initialQuantityMigrationSnapshot(t *testing.T, f *initialQuantityMigrationFixture) [3]string {
	t.Helper()
	var snapshot [3]string
	for i, table := range []string{"product_batches", "consumption_records", "change_log"} {
		order := "id"
		if table == "change_log" {
			order = "cursor"
		}
		query := "SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY " + order + "), '[]'::jsonb)::text FROM " + table + " AS r"
		if err := f.conn.QueryRowContext(f.ctx, query).Scan(&snapshot[i]); err != nil {
			t.Fatal(err)
		}
	}
	return snapshot
}

func assertInitialQuantityMigration(t *testing.T, f *initialQuantityMigrationFixture, batches []initialQuantityMigrationBatch, beforeRows, beforeStable []string, existingLogs int) {
	t.Helper()
	wantLogs := existingLogs
	for i, batch := range batches {
		wantVersion := batch.version
		repaired := batch.wantInitial != batch.initial
		wantBatchLogs := 0
		if repaired {
			wantVersion++
			wantBatchLogs = 1
			wantLogs++
		}
		var quantity, initial int
		var version int64
		var updated time.Time
		if err := f.conn.QueryRowContext(f.ctx, `
SELECT quantity, initial_quantity, version, updated_at FROM product_batches WHERE id = $1::uuid`,
			batch.id).Scan(&quantity, &initial, &version, &updated); err != nil {
			t.Fatal(err)
		}
		if quantity != batch.quantity || initial != batch.wantInitial || version != wantVersion {
			t.Errorf("%s: quantity/initial/version = %d/%d/%d; want %d/%d/%d",
				batch.name, quantity, initial, version, batch.quantity, batch.wantInitial, wantVersion)
		}
		if repaired {
			if !updated.After(time.Date(2020, 2, 1, 0, 0, 0, 0, time.UTC)) {
				t.Errorf("%s: updated_at was not advanced", batch.name)
			}
			if got := initialQuantityMigrationBatchJSON(t, f, batch.id, true); got != beforeStable[i] {
				t.Errorf("%s: repair changed unrelated batch fields", batch.name)
			}
		} else if got := initialQuantityMigrationBatchJSON(t, f, batch.id, false); got != beforeRows[i] {
			t.Errorf("%s: unchanged/deleted batch was rewritten", batch.name)
		}
		var logCount int
		var validPayload bool
		if err := f.conn.QueryRowContext(f.ctx, `
SELECT count(*), COALESCE(bool_and(
    c.cursor > 0 AND c.change_id <> '00000000-0000-0000-0000-000000000000'::uuid
    AND c.family_id = $2::uuid AND c.operation = 'entity_upsert'
    AND c.entity = 'product_batches' AND c.version = $3
    AND c.payload = (SELECT to_jsonb(b) - 'family_id' FROM product_batches AS b WHERE b.id = $1::uuid)
    AND NOT (c.payload ? 'family_id')
    AND c.created_at = (SELECT b.updated_at FROM product_batches AS b WHERE b.id = $1::uuid)
    AND c.updated_by_device IS NOT DISTINCT FROM
        (SELECT b.updated_by_device FROM product_batches AS b WHERE b.id = $1::uuid)
), false)
FROM change_log AS c WHERE c.entity_id = $1::uuid`,
			batch.id, batch.family, wantVersion).Scan(&logCount, &validPayload); err != nil {
			t.Fatal(err)
		}
		if logCount != wantBatchLogs || (repaired && !validPayload) {
			t.Errorf("%s: change logs = %d, full payload/metadata valid = %t; want %d valid logs",
				batch.name, logCount, validPayload, wantBatchLogs)
		}
	}
	var gotLogs int
	if err := f.conn.QueryRowContext(f.ctx, "SELECT count(*) FROM change_log").Scan(&gotLogs); err != nil {
		t.Fatal(err)
	}
	if gotLogs != wantLogs {
		t.Errorf("change_log rows = %d; want %d", gotLogs, wantLogs)
	}
}

func captureInitialQuantityMigrationRows(t *testing.T, f *initialQuantityMigrationFixture, batches []initialQuantityMigrationBatch) ([]string, []string) {
	t.Helper()
	var rows, stable []string
	for _, batch := range batches {
		rows = append(rows, initialQuantityMigrationBatchJSON(t, f, batch.id, false))
		stable = append(stable, initialQuantityMigrationBatchJSON(t, f, batch.id, true))
	}
	return rows, stable
}

func TestPostgresInitialQuantityMigrationRepairAndIdempotence(t *testing.T) {
	f := newInitialQuantityMigrationFixture(t)
	batches := seedInitialQuantityMigration(t, f)
	rows, stable := captureInitialQuantityMigrationRows(t, f, batches)
	before := initialQuantityMigrationSnapshot(t, f)
	if err := f.migrate(); err != nil {
		t.Fatalf("execute actual initial quantity migration: %v", err)
	}
	assertInitialQuantityMigration(t, f, batches, rows, stable, 0)
	first := initialQuantityMigrationSnapshot(t, f)
	if first[1] != before[1] {
		t.Fatal("repair rewrote consumption history")
	}
	if err := f.migrate(); err != nil {
		t.Fatalf("execute actual initial quantity migration a second time: %v", err)
	}
	if second := initialQuantityMigrationSnapshot(t, f); second != first {
		t.Fatal("second migration changed batch versions/timestamps, history or change logs")
	}
}

func TestPostgresInitialQuantityMigrationFailureRollsBack(t *testing.T) {
	for _, deferred := range []bool{false, true} {
		t.Run(fmt.Sprintf("deferred_commit_failure_%t", deferred), func(t *testing.T) {
			f := newInitialQuantityMigrationFixture(t)
			batches := seedInitialQuantityMigration(t, f)
			// Existing history/logs must survive failures, not merely stay empty.
			f.exec(t, `
INSERT INTO change_log (family_id, operation, entity, entity_id, version, payload)
VALUES ($1::uuid, 'entity_upsert', 'products', $2::uuid, 1, '{"preexisting":true}'::jsonb)`,
				initialQuantityMigrationFamilyA, initialQuantityMigrationProduct)
			rows, stable := captureInitialQuantityMigrationRows(t, f, batches)
			before := initialQuantityMigrationSnapshot(t, f)
			f.exec(t, `
CREATE FUNCTION initial_quantity_migration_fail() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'injected initial quantity migration failure' USING ERRCODE = 'P0001';
END;
$$;`)
			trigger := "CREATE TRIGGER initial_quantity_migration_fail BEFORE INSERT ON change_log" +
				" FOR EACH ROW EXECUTE FUNCTION initial_quantity_migration_fail()"
			if deferred {
				// All updates and log inserts succeed first; COMMIT then fails.
				trigger = "CREATE CONSTRAINT TRIGGER initial_quantity_migration_fail AFTER INSERT ON change_log" +
					" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION initial_quantity_migration_fail()"
			}
			f.exec(t, trigger)
			err := f.migrate()
			var pgErr *pgconn.PgError
			if !errors.As(err, &pgErr) || pgErr.Code != "P0001" ||
				pgErr.Message != "injected initial quantity migration failure" {
				t.Fatalf("expected injected PostgreSQL migration failure, got %v", err)
			}
			if after := initialQuantityMigrationSnapshot(t, f); after != before {
				t.Fatal("failed migration left partial batch updates, history changes or change logs")
			}
			f.exec(t, "DROP TRIGGER initial_quantity_migration_fail ON change_log")
			if err := f.migrate(); err != nil {
				t.Fatalf("retry actual migration after removing injected failure: %v", err)
			}
			assertInitialQuantityMigration(t, f, batches, rows, stable, 1)
			first := initialQuantityMigrationSnapshot(t, f)
			if first[1] != before[1] {
				t.Fatal("successful retry rewrote consumption history")
			}
			if err := f.migrate(); err != nil {
				t.Fatalf("repeat actual migration after successful retry: %v", err)
			}
			if second := initialQuantityMigrationSnapshot(t, f); second != first {
				t.Fatal("migration retry was not idempotent")
			}
		})
	}
}

func TestPostgresInitialQuantityMigrationOverflowRollsBack(t *testing.T) {
	f := newInitialQuantityMigrationFixture(t)
	batches := seedInitialQuantityMigration(t, f)
	// Each recorded restock fits integer, but the provable cumulative amount
	// exceeds its storage type. The migration must fail, not truncate it.
	seedInitialQuantityMigrationRecord(t, f, batches[0].family, batches[0].id,
		"restock", 2147483647, "initial-quantity-overflow-restock")
	before := initialQuantityMigrationSnapshot(t, f)
	err := f.migrate()
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "22003" {
		t.Fatalf("expected numeric out-of-range failure, got %v", err)
	}
	if after := initialQuantityMigrationSnapshot(t, f); after != before {
		t.Fatal("overflow left partial batch/version/log changes")
	}
}
