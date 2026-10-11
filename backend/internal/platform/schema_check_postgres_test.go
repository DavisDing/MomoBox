package platform

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

// Only the explicit CI/test URL opts in. Never use DATABASE_URL or a localhost
// fallback. Every connection is restricted to a fresh isolated test schema.
func TestReadMigrationSchemaPostgresReadOnlySnapshot(t *testing.T) {
	dsn := strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL"))
	if dsn == "" {
		t.Skip("MOMO_TEST_DATABASE_URL unset; schema-check PostgreSQL regression not executed")
	}
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid explicit PostgreSQL test configuration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin := stdlib.OpenDB(*config)
	defer admin.Close()
	var entropy [12]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	schema := "momobox_schema_check_test_" + hex.EncodeToString(entropy[:])
	if _, err := admin.ExecContext(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal("could not create isolated test schema")
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := admin.ExecContext(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error("isolated test schema cleanup failed")
		}
	}()
	scoped := config.Copy()
	if scoped.RuntimeParams == nil {
		scoped.RuntimeParams = make(map[string]string)
	}
	scoped.RuntimeParams["search_path"] = schema
	db := stdlib.OpenDB(*scoped)
	defer db.Close()
	db.SetMaxOpenConns(1)
	if _, err := ReadMigrationSchema(ctx, db); err == nil {
		t.Fatal("missing ledger was accepted")
	}
	var exists bool
	if err := db.QueryRowContext(ctx, "SELECT to_regclass('schema_migrations') IS NOT NULL").Scan(&exists); err != nil || exists {
		t.Fatal("read-only checker created a missing ledger or leaked its transaction")
	}
	// The view asserts transaction flags inside the checker's actual SELECT.
	// It is a test fixture, not a production migration or schema repair.
	if _, err := db.ExecContext(ctx, `
CREATE TABLE ledger_fixture (version bigint PRIMARY KEY, name text NOT NULL, checksum text NOT NULL);
CREATE FUNCTION assert_readonly_snapshot() RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('transaction_read_only') <> 'on' OR
       current_setting('transaction_isolation') <> 'repeatable read' THEN
        RAISE EXCEPTION 'checker requires a read-only repeatable-read snapshot';
    END IF;
    RETURN true;
END;
$$;
CREATE VIEW schema_migrations AS SELECT version, name, checksum FROM ledger_fixture WHERE assert_readonly_snapshot();
INSERT INTO ledger_fixture VALUES (2, '0002_second.sql', 'sha256:second'), (1, '0001_first.sql', 'sha256:first');
`); err != nil {
		t.Fatal("could not create isolated read-only fixture")
	}
	records, err := ReadMigrationSchema(ctx, db)
	if err != nil {
		t.Fatalf("read-only snapshot failed: %v", err)
	}
	if len(records) != 2 || records[0].Version != 1 || records[1].Version != 2 || records[0].Checksum != "sha256:first" {
		t.Fatalf("incorrect ordered records: %#v", records)
	}
	var count int
	if err := db.QueryRowContext(ctx, "SELECT count(*) FROM ledger_fixture").Scan(&count); err != nil || count != 2 {
		t.Fatal("checker changed records or failed to release its read transaction")
	}
	cancelled, stop := context.WithCancel(ctx)
	stop()
	if _, err := ReadMigrationSchema(cancelled, db); err == nil {
		t.Fatal("cancelled check succeeded")
	}
	if db.Stats().InUse != 0 {
		t.Fatal("schema read leaked a connection")
	}
}
