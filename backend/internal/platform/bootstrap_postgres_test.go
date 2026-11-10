package platform

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
)

// Shipped migrations explicitly target public, so these tests create a fresh
// database using only the opt-in CI/test URL. No application URL is read and
// cleanup can target only the random database successfully created here.
func automaticMigrationPostgres(t *testing.T) (context.Context, *sql.DB, SQLMigrationRunner) {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL"))
	if dsn == "" {
		t.Skip("MOMO_TEST_DATABASE_URL unset; automatic startup PostgreSQL regression not executed")
	}
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid explicit PostgreSQL test configuration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	admin := stdlib.OpenDB(*config)
	t.Cleanup(func() { _ = admin.Close() })
	var entropy [12]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	name := "momobox_start_test_" + hex.EncodeToString(entropy[:])
	if _, err := admin.ExecContext(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatal("could not create isolated startup test database; test role needs CREATEDB")
	}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if _, err := admin.ExecContext(cleanup, "DROP DATABASE "+name+" WITH (FORCE)"); err != nil {
			t.Error("could not clean up isolated startup test database")
		}
	})
	scoped := config.Copy()
	scoped.Database = name
	if scoped.RuntimeParams == nil {
		scoped.RuntimeParams = make(map[string]string)
	}
	scoped.RuntimeParams["search_path"] = "public"
	db := stdlib.OpenDB(*scoped)
	t.Cleanup(func() { _ = db.Close() })
	migrationConfig := scoped.Copy()
	// A connection-level search_path must not hide public from bootstrap.
	migrationConfig.RuntimeParams["search_path"] = "pg_catalog"
	return ctx, db, SQLMigrationRunner{
		DatabaseURL: "isolated-test-database", Directory: "../../migrations", RequireEmptyBootstrap: true,
		Open: func(string) (DB, error) { return SQLDB{DB: stdlib.OpenDB(*migrationConfig)}, nil },
	}
}

func TestAutomaticStartupPostgresInitializesOnceAndPreservesData(t *testing.T) {
	ctx, db, runner := automaticMigrationPostgres(t)
	// Administrators may install pgcrypto before granting the application role.
	if _, err := db.ExecContext(ctx, "CREATE EXTENSION pgcrypto"); err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	errors := make(chan error, 2)
	for i := 0; i < 2; i++ {
		group.Add(1)
		go func() { defer group.Done(); errors <- runner.Run(ctx) }()
	}
	group.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatalf("concurrent initialization failed: %v", err)
		}
	}
	const userID = "f41c47f9-6b0a-4ab5-a1fc-97e3a40e10b7"
	if _, err := db.ExecContext(ctx, `INSERT INTO users (id, email, password_hash, nickname) VALUES ($1, 'startup@example.invalid', 'test-only', 'preserve-me')`, userID); err != nil {
		t.Fatal(err)
	}
	before, err := ReadMigrationSchema(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	if err := runner.Run(ctx); err != nil {
		t.Fatalf("restart failed: %v", err)
	}
	var nickname string
	if err := db.QueryRowContext(ctx, "SELECT nickname FROM users WHERE id = $1", userID).Scan(&nickname); err != nil || nickname != "preserve-me" {
		t.Fatalf("restart changed existing data: %v", err)
	}
	after, err := ReadMigrationSchema(ctx, db)
	if err != nil || len(before) != len(after) {
		t.Fatalf("restart changed migration history: %v", err)
	}
	for i := range before {
		if before[i] != after[i] {
			t.Fatal("restart rewrote an applied migration")
		}
	}
	if err := CheckMigrationSchema(ctx, runner.Directory, func(ctx context.Context) ([]MigrationRecord, error) { return ReadMigrationSchema(ctx, db) }); err != nil {
		t.Fatal(err)
	}
}

func TestAutomaticStartupPostgresRejectsUntrackedObjectsAndSearchPathOverride(t *testing.T) {
	ctx, db, runner := automaticMigrationPostgres(t)
	if _, err := db.ExecContext(ctx, "CREATE TABLE keep_me (value text); INSERT INTO keep_me VALUES ('existing')"); err != nil {
		t.Fatal(err)
	}
	if err := runner.Run(ctx); !errors.Is(err, ErrUntrackedDatabase) {
		t.Fatalf("untracked public schema was treated as empty: %v", err)
	}
	var exists bool
	if err := db.QueryRowContext(ctx, "SELECT to_regclass('public.schema_migrations') IS NOT NULL").Scan(&exists); err != nil || exists {
		t.Fatal("automatic startup created a ledger in an untracked database")
	}
	var value string
	if err := db.QueryRowContext(ctx, "SELECT value FROM keep_me").Scan(&value); err != nil || value != "existing" {
		t.Fatal("untracked data was modified")
	}
	if _, err := db.ExecContext(ctx, "CREATE TABLE schema_migrations (version bigint PRIMARY KEY, name text, checksum text)"); err != nil {
		t.Fatal(err)
	}
	if err := runner.Run(ctx); !errors.Is(err, ErrUntrackedDatabase) {
		t.Fatalf("empty ledger hid existing data: %v", err)
	}
}

func TestAutomaticStartupPostgresResumesFailedPendingMigration(t *testing.T) {
	ctx, db, runner := automaticMigrationPostgres(t)
	runner.Directory = t.TempDir()
	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(runner.Directory, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("0001_first.sql", "CREATE TABLE fixture (value text); INSERT INTO fixture VALUES ('preserved');")
	if err := runner.Run(ctx); err != nil {
		t.Fatal(err)
	}
	write("0002_pending.sql", "ALTER TABLE fixture ADD COLUMN label text; SELECT * FROM missing_prerequisite;")
	if err := runner.Run(ctx); err == nil {
		t.Fatal("invalid migration succeeded")
	}
	var count int
	if err := db.QueryRowContext(ctx, "SELECT count(*) FROM schema_migrations").Scan(&count); err != nil || count != 1 {
		t.Fatal("failed migration was recorded")
	}
	// Resolve the missing prerequisite without modifying a committed migration.
	if _, err := db.ExecContext(ctx, "CREATE TABLE missing_prerequisite (value text)"); err != nil {
		t.Fatal(err)
	}
	if err := runner.Run(ctx); err != nil {
		t.Fatalf("could not resume pending migration: %v", err)
	}
	var value string
	if err := db.QueryRowContext(ctx, "SELECT value FROM fixture").Scan(&value); err != nil || value != "preserved" {
		t.Fatal("resuming pending migration changed existing data")
	}
	if _, err := db.ExecContext(ctx, "UPDATE schema_migrations SET checksum = 'changed' WHERE version = 1"); err != nil {
		t.Fatal(err)
	}
	if err := runner.Run(ctx); !errors.Is(err, ErrMigrationChecksumMismatch) {
		t.Fatalf("corrupt migration identity accepted: %v", err)
	}
}
