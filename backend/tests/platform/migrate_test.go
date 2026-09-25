package platform_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/momobox/backend/internal/platform"
)

type migrationFakeDB struct {
	records       map[int64]platform.MigrationRecord
	executed      []string
	beginCount    int
	lockCount     int
	ensureCount   int
	commitCount   int
	rollbackCount int
	pingErr       error
	executeErr    error
}

func newMigrationFakeDB(records ...platform.MigrationRecord) *migrationFakeDB {
	stored := make(map[int64]platform.MigrationRecord, len(records))
	for _, record := range records {
		stored[record.Version] = record
	}
	return &migrationFakeDB{records: stored}
}

func (db *migrationFakeDB) PingContext(context.Context) error { return db.pingErr }
func (db *migrationFakeDB) Close() error                      { return nil }

func (db *migrationFakeDB) BeginMigration(context.Context) (platform.MigrationTransaction, error) {
	db.beginCount++
	working := make(map[int64]platform.MigrationRecord, len(db.records))
	for version, record := range db.records {
		working[version] = record
	}
	return &migrationFakeTx{db: db, working: working}, nil
}

type migrationFakeTx struct {
	db        *migrationFakeDB
	working   map[int64]platform.MigrationRecord
	committed bool
}

func (tx *migrationFakeTx) AdvisoryLock(context.Context) error {
	tx.db.lockCount++
	return nil
}

func (tx *migrationFakeTx) EnsureSchemaMigrations(context.Context) error {
	tx.db.ensureCount++
	return nil
}

func (tx *migrationFakeTx) AppliedMigrations(context.Context) ([]platform.MigrationRecord, error) {
	result := make([]platform.MigrationRecord, 0, len(tx.working))
	for _, record := range tx.working {
		result = append(result, record)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Version < result[j].Version })
	return result, nil
}

func (tx *migrationFakeTx) ExecuteMigration(_ context.Context, contents string) error {
	if tx.db.executeErr != nil {
		return tx.db.executeErr
	}
	tx.db.executed = append(tx.db.executed, contents)
	return nil
}

func (tx *migrationFakeTx) InsertMigration(_ context.Context, record platform.MigrationRecord) error {
	tx.working[record.Version] = record
	return nil
}

func (tx *migrationFakeTx) UpdateMigrationChecksum(_ context.Context, version int64, checksum string) error {
	record, ok := tx.working[version]
	if !ok {
		return errors.New("migration record not found")
	}
	record.Checksum = checksum
	tx.working[version] = record
	return nil
}

func (tx *migrationFakeTx) Commit() error {
	if tx.committed {
		return nil
	}
	tx.db.records = tx.working
	tx.db.commitCount++
	tx.committed = true
	return nil
}

func (tx *migrationFakeTx) Rollback() error {
	if tx.committed {
		return nil
	}
	tx.db.rollbackCount++
	return nil
}

func writeMigration(t *testing.T, directory, name, contents string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(directory, name), []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}

func runWithFake(t *testing.T, directory string, db *migrationFakeDB) error {
	t.Helper()
	return (platform.SQLMigrationRunner{
		DatabaseURL: "postgres://test",
		Directory:   directory,
		Open: func(string) (platform.DB, error) {
			return db, nil
		},
	}).Run(context.Background())
}

func TestSQLMigrationRunnerAppliesInNumericOrderAndRecordsChecksum(t *testing.T) {
	directory := t.TempDir()
	writeMigration(t, directory, "0002_second.sql", "SELECT 2;")
	writeMigration(t, directory, "0010_tenth.sql", "SELECT 10;")
	writeMigration(t, directory, "0001_first.sql", "BEGIN;\nSELECT 1;\nCOMMIT;\n")
	db := newMigrationFakeDB()

	if err := runWithFake(t, directory, db); err != nil {
		t.Fatal(err)
	}
	if len(db.executed) != 3 {
		t.Fatalf("executed %d migrations, want 3", len(db.executed))
	}
	if !strings.Contains(db.executed[0], "SELECT 1") || strings.Contains(db.executed[0], "BEGIN") || strings.Contains(db.executed[0], "COMMIT") {
		t.Fatalf("outer transaction was not stripped: %q", db.executed[0])
	}
	if !strings.Contains(db.executed[1], "SELECT 2") || !strings.Contains(db.executed[2], "SELECT 10") {
		t.Fatalf("migrations were not executed in numeric order: %#v", db.executed)
	}
	if len(db.records) != 3 {
		t.Fatalf("record count = %d, want 3", len(db.records))
	}
	for version, name := range map[int64]string{1: "0001_first.sql", 2: "0002_second.sql", 10: "0010_tenth.sql"} {
		record, ok := db.records[version]
		if !ok || record.Name != name || !strings.HasPrefix(record.Checksum, "sha256:") {
			t.Fatalf("unexpected record for version %d: %#v", version, record)
		}
	}
	if db.lockCount != 3 || db.ensureCount != 3 || db.commitCount != 3 {
		t.Fatalf("transaction controls = locks %d, ensure %d, commits %d", db.lockCount, db.ensureCount, db.commitCount)
	}
}

func TestSQLMigrationRunnerSkipsAppliedMigrationAndDetectsModifiedFile(t *testing.T) {
	directory := t.TempDir()
	writeMigration(t, directory, "0001_first.sql", "SELECT 1;")
	db := newMigrationFakeDB()

	if err := runWithFake(t, directory, db); err != nil {
		t.Fatal(err)
	}
	if err := runWithFake(t, directory, db); err != nil {
		t.Fatalf("repeat run failed: %v", err)
	}
	if len(db.executed) != 1 {
		t.Fatalf("applied migration executed %d times, want 1", len(db.executed))
	}

	writeMigration(t, directory, "0001_first.sql", "SELECT 999;")
	err := runWithFake(t, directory, db)
	if !errors.Is(err, platform.ErrMigrationChecksumMismatch) {
		t.Fatalf("error = %v, want checksum mismatch", err)
	}
	if len(db.executed) != 1 {
		t.Fatalf("modified migration was executed, got %d executions", len(db.executed))
	}
}

func TestSQLMigrationRunnerRejectsNameAndUnknownVersion(t *testing.T) {
	directory := t.TempDir()
	writeMigration(t, directory, "0001_first.sql", "SELECT 1;")

	db := newMigrationFakeDB(platform.MigrationRecord{Version: 1, Name: "renamed.sql", Checksum: "sha256:any"})
	err := runWithFake(t, directory, db)
	if !errors.Is(err, platform.ErrMigrationNameMismatch) {
		t.Fatalf("name error = %v, want name mismatch", err)
	}

	db = newMigrationFakeDB(platform.MigrationRecord{Version: 9, Name: "0009_missing.sql", Checksum: "sha256:any"})
	err = runWithFake(t, directory, db)
	if !errors.Is(err, platform.ErrUnknownAppliedMigration) {
		t.Fatalf("unknown version error = %v, want unknown applied migration", err)
	}
}

func TestSQLMigrationRunnerRollsBackWhenExecutionFails(t *testing.T) {
	directory := t.TempDir()
	writeMigration(t, directory, "0001_first.sql", "SELECT failure;")
	db := newMigrationFakeDB()
	db.executeErr = errors.New("syntax error")

	if err := runWithFake(t, directory, db); err == nil {
		t.Fatal("migration unexpectedly succeeded")
	}
	if len(db.records) != 0 {
		t.Fatalf("records changed after failed migration: %#v", db.records)
	}
	if db.commitCount != 0 || db.rollbackCount != 1 {
		t.Fatalf("commit/rollback = %d/%d, want 0/1", db.commitCount, db.rollbackCount)
	}
}

func TestSQLMigrationRunnerRejectsInvalidAndDuplicateFilenames(t *testing.T) {
	directory := t.TempDir()
	writeMigration(t, directory, "migration.sql", "SELECT 1;")
	db := newMigrationFakeDB()
	if err := runWithFake(t, directory, db); !errors.Is(err, platform.ErrInvalidMigrationFilename) {
		t.Fatalf("invalid filename error = %v", err)
	}

	directory = t.TempDir()
	writeMigration(t, directory, "0001_first.sql", "SELECT 1;")
	writeMigration(t, directory, "0001_other.sql", "SELECT 1;")
	if err := runWithFake(t, directory, db); !errors.Is(err, platform.ErrDuplicateMigrationVersion) {
		t.Fatalf("duplicate version error = %v", err)
	}
}
