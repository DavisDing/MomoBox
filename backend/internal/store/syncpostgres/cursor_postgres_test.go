package syncpostgres

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// CI provides a disposable PostgreSQL service. Without that explicit test URL
// this integration test is skipped; contract/unit tests do not prove ordering.
func TestPostgresCursorCommitOrderAndReminderMigration(t *testing.T) {
	url := os.Getenv("MOMO_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MOMO_TEST_DATABASE_URL is unset; real PostgreSQL validation not executed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(5)
	if err := db.PingContext(ctx); err != nil {
		t.Fatal(err)
	}
	var entropy [8]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	// Only a generated identifier is interpolated, never a URL or user value.
	schema := "momobox_cursor_test_" + hex.EncodeToString(entropy[:])
	if _, err := db.ExecContext(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := db.ExecContext(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Errorf("clean up isolated test schema: %v", err)
		}
	}()
	setup := fmt.Sprintf(`
CREATE TABLE %s.reminder_settings (id integer PRIMARY KEY, expiry_warning_days integer NOT NULL DEFAULT 7);
INSERT INTO %s.reminder_settings (id) VALUES (1);
CREATE TABLE %s.change_log (cursor bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, marker text NOT NULL);
`, schema, schema, schema)
	if _, err := db.ExecContext(ctx, setup); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile("../../../migrations/0005_reminder_defaults_and_cursor_order.sql")
	if err != nil {
		t.Fatal(err)
	}
	// Execute the actual migration twice, replacing only its public schema
	// references so the test cannot touch production tables in the supplied DB.
	migration := strings.ReplaceAll(string(raw), "SET LOCAL search_path = public;", "SET LOCAL search_path = "+schema+";")
	migration = strings.ReplaceAll(migration, "'public.change_log'", "'"+schema+".change_log'")
	for i := 0; i < 2; i++ {
		if _, err := db.ExecContext(ctx, migration); err != nil {
			t.Fatalf("migration execution %d: %v", i+1, err)
		}
	}
	if _, err := db.ExecContext(ctx, "INSERT INTO "+schema+".reminder_settings (id) VALUES (2)"); err != nil {
		t.Fatal(err)
	}
	var oldDays, newDays int
	if err := db.QueryRowContext(ctx, "SELECT expiry_warning_days FROM "+schema+".reminder_settings WHERE id=1").Scan(&oldDays); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRowContext(ctx, "SELECT expiry_warning_days FROM "+schema+".reminder_settings WHERE id=2").Scan(&newDays); err != nil {
		t.Fatal(err)
	}
	if oldDays != 7 || newDays != 30 {
		t.Fatalf("existing/new reminder days = %d/%d, want 7/30", oldDays, newDays)
	}

	for _, rollbackFirst := range []bool{false, true} {
		t.Run(fmt.Sprintf("rollback_first_%t", rollbackFirst), func(t *testing.T) {
			first, err := db.BeginTx(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer first.Rollback()
			var firstCursor int64
			if err := first.QueryRowContext(ctx, "INSERT INTO "+schema+".change_log(marker) VALUES ('first') RETURNING cursor").Scan(&firstCursor); err != nil {
				t.Fatal(err)
			}
			secondConn, err := db.Conn(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer secondConn.Close()
			var secondPID int
			if err := secondConn.QueryRowContext(ctx, "SELECT pg_backend_pid()").Scan(&secondPID); err != nil {
				t.Fatal(err)
			}
			second, err := secondConn.BeginTx(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer second.Rollback()
			type insertResult struct { cursor int64; err error }
			result := make(chan insertResult, 1)
			go func() {
				var cursor int64
				err := second.QueryRowContext(ctx, "INSERT INTO "+schema+".change_log(marker) VALUES ('second') RETURNING cursor").Scan(&cursor)
				if err == nil { err = second.Commit() } else { _ = second.Rollback() }
				result <- insertResult{cursor: cursor, err: err}
			}()
			// Confirm it is blocked on the advisory lock, not merely an
			// unscheduled goroutine. Do not use a sleep as proof of ordering.
			deadline := time.Now().Add(5*time.Second)
			for {
				var waiting bool
				if err := db.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND wait_event_type='Lock' AND wait_event='advisory')`, secondPID).Scan(&waiting); err != nil {
					t.Fatal(err)
				}
				if waiting { break }
				select { case done := <-result: t.Fatalf("second insert completed before first transaction: %+v", done); default: }
				if time.Now().After(deadline) { t.Fatal("second insert did not wait for the cursor lock") }
				time.Sleep(10*time.Millisecond)
			}
			// BEFORE STATEMENT must execute before the identity default. A
			// row trigger would already have advanced last_value at this point.
			var allocated int64
			if err := db.QueryRowContext(ctx, "SELECT last_value FROM "+schema+".change_log_cursor_seq").Scan(&allocated); err != nil {
				t.Fatal(err)
			}
			if allocated != firstCursor { t.Fatalf("waiting insert allocated cursor %d before first commit; want %d", allocated, firstCursor) }
			var visible int64
			if err := db.QueryRowContext(ctx, "SELECT COALESCE(MAX(cursor),0) FROM "+schema+".change_log").Scan(&visible); err != nil { t.Fatal(err) }
			if visible >= firstCursor { t.Fatal("uncommitted cursor was visible") }
			if rollbackFirst { err = first.Rollback() } else { err = first.Commit() }
			if err != nil { t.Fatal(err) }
			select {
			case done := <-result:
				if done.err != nil { t.Fatal(done.err) }
				if done.cursor <= firstCursor { t.Fatalf("second cursor %d must exceed %d", done.cursor, firstCursor) }
			case <-ctx.Done(): t.Fatal("waiting cursor did not resume: ", ctx.Err())
			}
			var firstExists bool
			if err := db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM "+schema+".change_log WHERE cursor=$1)", firstCursor).Scan(&firstExists); err != nil { t.Fatal(err) }
			if firstExists == rollbackFirst { t.Fatal("first commit/rollback was not reflected") }
		})
	}
}
