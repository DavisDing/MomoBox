package platform_test

import (
	"context"
	"errors"
	"testing"

	"github.com/momobox/backend/internal/platform"
)

func automaticRunner(directory string, db *migrationFakeDB) platform.SQLMigrationRunner {
	return platform.SQLMigrationRunner{
		DatabaseURL: "postgres://test", Directory: directory,
		RequireEmptyBootstrap: true,
		Open:                  func(string) (platform.DB, error) { return db, nil },
	}
}

func TestAutomaticMigrationsInitializeResumeAndPreserveAppliedData(t *testing.T) {
	dir := t.TempDir()
	writeMigration(t, dir, "0001_first.sql", "CREATE TABLE fixture (value text);")
	db := newMigrationFakeDB()
	runner := automaticRunner(dir, db)
	if err := runner.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := runner.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(db.executed) != 1 {
		t.Fatalf("restart reexecuted migration: %v", db.executed)
	}
	first := db.records[1]
	writeMigration(t, dir, "0002_second.sql", "ALTER TABLE fixture ADD COLUMN label text;")
	if err := runner.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(db.executed) != 2 || len(db.records) != 2 || db.records[1] != first || db.bootstrapChecks == 0 {
		t.Fatalf("pending migration did not preserve applied history: %#v", db)
	}
}

func TestAutomaticMigrationsRefuseUntrackedDatabaseBeforeCreatingLedger(t *testing.T) {
	dir := t.TempDir()
	writeMigration(t, dir, "0001_first.sql", "SELECT 1;")
	db := newMigrationFakeDB()
	db.bootstrapErr = platform.ErrUntrackedDatabase
	if err := automaticRunner(dir, db).Run(context.Background()); !errors.Is(err, platform.ErrUntrackedDatabase) {
		t.Fatalf("got %v, want untracked database", err)
	}
	if db.ensureCount != 0 || len(db.executed) != 0 || len(db.records) != 0 || db.lockCount != 1 || db.rollbackCount != 1 {
		t.Fatalf("unsafe initialization or missing lock/rollback: %#v", db)
	}
}

func TestAutomaticMigrationsResumeAfterFailureWithoutReplayingCommittedSQL(t *testing.T) {
	dir := t.TempDir()
	writeMigration(t, dir, "0001_first.sql", "SELECT 1;")
	db := newMigrationFakeDB()
	runner := automaticRunner(dir, db)
	if err := runner.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	writeMigration(t, dir, "0002_second.sql", "SELECT 2;")
	db.executeErr = errors.New("migration failed")
	if err := runner.Run(context.Background()); err == nil || len(db.records) != 1 {
		t.Fatalf("failed migration was recorded: %v / %#v", err, db.records)
	}
	db.executeErr = nil
	if err := runner.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(db.executed) != 2 || len(db.records) != 2 {
		t.Fatalf("did not resume safely: %#v", db)
	}
}

func TestAutomaticMigrationsRejectChangedOrNewerHistory(t *testing.T) {
	dir := t.TempDir()
	writeMigration(t, dir, "0001_first.sql", "SELECT 1;")
	db := newMigrationFakeDB()
	runner := automaticRunner(dir, db)
	if err := runner.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	writeMigration(t, dir, "0001_first.sql", "SELECT 999;")
	if err := runner.Run(context.Background()); !errors.Is(err, platform.ErrMigrationChecksumMismatch) {
		t.Fatalf("changed checksum accepted: %v", err)
	}
	if len(db.executed) != 1 {
		t.Fatal("changed migration was executed")
	}
	db = newMigrationFakeDB(platform.MigrationRecord{Version: 9, Name: "0009_future.sql"})
	if err := automaticRunner(dir, db).Run(context.Background()); !errors.Is(err, platform.ErrUnknownAppliedMigration) {
		t.Fatalf("newer history accepted: %v", err)
	}
	if len(db.executed) != 0 {
		t.Fatal("migration executed against newer schema")
	}
}

func TestAutomaticMigrationsRefuseGapInAppliedHistory(t *testing.T) {
	dir := t.TempDir()
	writeMigration(t, dir, "0001_first.sql", "SELECT 1;")
	writeMigration(t, dir, "0002_second.sql", "SELECT 2;")
	db := newMigrationFakeDB()
	runner := automaticRunner(dir, db)
	if err := runner.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	delete(db.records, 1)
	if err := runner.Run(context.Background()); !errors.Is(err, platform.ErrMigrationHistoryGap) {
		t.Fatalf("history gap accepted: %v", err)
	}
	if len(db.executed) != 2 || len(db.records) != 1 {
		t.Fatal("missing history was silently reconstructed")
	}
}
