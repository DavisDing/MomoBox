package platform

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var (
	ErrNoMigrations               = errors.New("no SQL migrations found")
	ErrInvalidMigrationFilename   = errors.New("invalid SQL migration filename")
	ErrDuplicateMigrationVersion = errors.New("duplicate SQL migration version")
	ErrUnknownAppliedMigration   = errors.New("database contains an unknown applied migration")
	ErrMigrationNameMismatch     = errors.New("applied migration name does not match the file")
	ErrMigrationChecksumMismatch = errors.New("applied migration checksum does not match the file")
)

const migrationAdvisoryLockSQL = `SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0))`

// MigrationRunner executes versioned SQL files.
type MigrationRunner interface{ Run(context.Context) error }

// MigrationRecord is the immutable identity recorded for an applied migration.
// The checksum is the sha256 digest of the exact migration file bytes, prefixed
// with "sha256:".
type MigrationRecord struct {
	Version  int64
	Name     string
	Checksum string
}

// MigrationDatabase and MigrationTransaction are deliberately small seams for
// the migration runner. Production uses the database/sql adapter below; tests
// can use an in-memory implementation without adding a third-party SQL mock.
type MigrationDatabase interface {
	DB
	BeginMigration(context.Context) (MigrationTransaction, error)
}

type MigrationTransaction interface {
	AdvisoryLock(context.Context) error
	EnsureSchemaMigrations(context.Context) error
	AppliedMigrations(context.Context) ([]MigrationRecord, error)
	ExecuteMigration(context.Context, string) error
	InsertMigration(context.Context, MigrationRecord) error
	UpdateMigrationChecksum(context.Context, int64, string) error
	Commit() error
	Rollback() error
}

type SQLMigrationRunner struct {
	DatabaseURL string
	Directory   string
	Open        func(string) (DB, error)
}

type migrationFile struct {
	version         int64
	name            string
	contents        string
	checksum        string
	legacyChecksum  string
	legacyName      string
	legacyVersion   int64
	hasLegacyMarker bool
}

var migrationFilenamePattern = regexp.MustCompile(`^(\d+)_([A-Za-z0-9][A-Za-z0-9._-]*)\.sql$`)
var legacyMigrationRecordPattern = regexp.MustCompile(`(?is)INSERT\s+INTO\s+schema_migrations\s*\(\s*version\s*,\s*name\s*,\s*checksum\s*\)\s*VALUES\s*\(\s*(\d+)\s*,\s*'((?:''|[^'])*)'\s*,\s*'([^']*)'\s*\)`)
var leadingBeginPattern = regexp.MustCompile(`(?is)^\s*(?:(?:--[^\n]*\n)|(?:/\*.*?\*/\s*))*BEGIN\s*;`)
var trailingCommitPattern = regexp.MustCompile(`(?is);\s*(?:(?:--[^\n]*\n)|(?:/\*.*?\*/\s*))*COMMIT\s*;\s*$`)

// legacyMigrationChecksums contains the exact file checksum for migrations
// whose SQL historically inserted a non-cryptographic compatibility marker.
// A legacy marker is accepted only for this immutable file identity; otherwise
// editing a legacy migration could silently bypass checksum verification.
var legacyMigrationChecksums = map[int64]string{
	1: "sha256:51bf0b495c5f3495031352f3a0ef7f07e00b630c97a74d04dd4e7a1a674415e7",
}

func (r SQLMigrationRunner) Run(ctx context.Context) error {
	if strings.TrimSpace(r.DatabaseURL) == "" {
		return errors.New("database URL is empty")
	}

	migrations, err := loadMigrationFiles(r.Directory)
	if err != nil {
		return err
	}

	open := r.Open
	if open == nil {
		open = OpenPostgresDefault
	}
	db, err := open(r.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Close()
	if err := db.PingContext(ctx); err != nil {
		return fmt.Errorf("ping postgres: %w", err)
	}

	migrationDB, ok := db.(MigrationDatabase)
	if !ok {
		migrationDB, ok = newSQLMigrationDatabase(db)
		if !ok {
			return errors.New("migration runner requires a database/sql-backed DB")
		}
	}

	known := make(map[int64]migrationFile, len(migrations))
	for _, migration := range migrations {
		known[migration.version] = migration
	}

	for _, migration := range migrations {
		if err := applyMigration(ctx, migrationDB, migration, known); err != nil {
			return fmt.Errorf("migration %s: %w", migration.name, err)
		}
	}
	return nil
}

func loadMigrationFiles(directory string) ([]migrationFile, error) {
	if strings.TrimSpace(directory) == "" {
		directory = "./migrations"
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, fmt.Errorf("read migrations directory: %w", err)
	}

	migrations := make([]migrationFile, 0, len(entries))
	seenVersions := make(map[int64]string)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		matches := migrationFilenamePattern.FindStringSubmatch(entry.Name())
		if matches == nil {
			return nil, fmt.Errorf("%w: %s", ErrInvalidMigrationFilename, entry.Name())
		}
		version, err := strconv.ParseInt(matches[1], 10, 64)
		if err != nil || version <= 0 {
			return nil, fmt.Errorf("%w: %s", ErrInvalidMigrationFilename, entry.Name())
		}
		if previous, exists := seenVersions[version]; exists {
			return nil, fmt.Errorf("%w: version %d is used by %s and %s", ErrDuplicateMigrationVersion, version, previous, entry.Name())
		}

		path := filepath.Join(directory, entry.Name())
		contents, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read migration %s: %w", entry.Name(), err)
		}
		migration := migrationFile{
			version:  version,
			name:     entry.Name(),
			contents: string(contents),
			checksum: checksumMigration(contents),
		}
		if legacyVersion, legacyName, legacyChecksum, ok := parseLegacyMigrationRecord(migration.contents); ok {
			migration.legacyVersion = legacyVersion
			migration.legacyName = legacyName
			migration.legacyChecksum = legacyChecksum
			migration.hasLegacyMarker = true
		}
		seenVersions[version] = entry.Name()
		migrations = append(migrations, migration)
	}
	if len(migrations) == 0 {
		return nil, ErrNoMigrations
	}
	sort.Slice(migrations, func(i, j int) bool { return migrations[i].version < migrations[j].version })
	return migrations, nil
}

func applyMigration(ctx context.Context, db MigrationDatabase, migration migrationFile, known map[int64]migrationFile) error {
	tx, err := db.BeginMigration(ctx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if err := tx.AdvisoryLock(ctx); err != nil {
		return fmt.Errorf("acquire advisory lock: %w", err)
	}
	if err := tx.EnsureSchemaMigrations(ctx); err != nil {
		return fmt.Errorf("ensure schema_migrations: %w", err)
	}

	applied, err := tx.AppliedMigrations(ctx)
	if err != nil {
		return fmt.Errorf("read schema_migrations: %w", err)
	}
	appliedByVersion := make(map[int64]MigrationRecord, len(applied))
	for _, record := range applied {
		appliedByVersion[record.Version] = record
		knownMigration, exists := known[record.Version]
		if !exists {
			return fmt.Errorf("%w: version %d (%s)", ErrUnknownAppliedMigration, record.Version, record.Name)
		}
		if err := validateMigrationRecord(record, knownMigration); err != nil {
			return err
		}
		if needsLegacyChecksumUpgrade(record, knownMigration) {
			if err := tx.UpdateMigrationChecksum(ctx, record.Version, knownMigration.checksum); err != nil {
				return fmt.Errorf("upgrade legacy checksum for version %d: %w", record.Version, err)
			}
		}
	}

	if record, exists := appliedByVersion[migration.version]; exists {
		if err := validateMigrationRecord(record, migration); err != nil {
			return err
		}
		return commitMigration(tx)
	}

	if err := tx.ExecuteMigration(ctx, stripOuterTransaction(migration.contents)); err != nil {
		return fmt.Errorf("execute SQL: %w", err)
	}

	applied, err = tx.AppliedMigrations(ctx)
	if err != nil {
		return fmt.Errorf("read schema_migrations after execution: %w", err)
	}
	var record *MigrationRecord
	for i := range applied {
		if applied[i].Version == migration.version {
			candidate := applied[i]
			record = &candidate
			break
		}
	}
	if record == nil {
		if err := tx.InsertMigration(ctx, MigrationRecord{Version: migration.version, Name: migration.name, Checksum: migration.checksum}); err != nil {
			return fmt.Errorf("record migration: %w", err)
		}
	} else {
		if err := validateMigrationRecord(*record, migration); err != nil {
			return err
		}
		if needsLegacyChecksumUpgrade(*record, migration) {
			if err := tx.UpdateMigrationChecksum(ctx, migration.version, migration.checksum); err != nil {
				return fmt.Errorf("upgrade legacy checksum for version %d: %w", migration.version, err)
			}
		}
	}

	return commitMigration(tx)
}

func validateMigrationRecord(record MigrationRecord, migration migrationFile) error {
	if record.Name != migration.name {
		return fmt.Errorf("%w: version %d is recorded as %q, file is %q", ErrMigrationNameMismatch, record.Version, record.Name, migration.name)
	}
	if record.Checksum == migration.checksum {
		return nil
	}
	if needsLegacyChecksumUpgrade(record, migration) {
		return nil
	}
	return fmt.Errorf("%w: version %d (%s), recorded %q, expected %q", ErrMigrationChecksumMismatch, record.Version, record.Name, record.Checksum, migration.checksum)
}

func needsLegacyChecksumUpgrade(record MigrationRecord, migration migrationFile) bool {
	if !migration.hasLegacyMarker ||
		record.Version != migration.legacyVersion ||
		record.Name != migration.legacyName ||
		record.Checksum != migration.legacyChecksum ||
		migration.legacyChecksum == migration.checksum ||
		migration.legacyVersion != migration.version ||
		migration.legacyName != migration.name {
		return false
	}
	expectedChecksum, ok := legacyMigrationChecksums[migration.version]
	return ok && migration.checksum == expectedChecksum
}

func commitMigration(tx MigrationTransaction) error {
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}
	return nil
}

func checksumMigration(contents []byte) string {
	digest := sha256.Sum256(contents)
	return "sha256:" + hex.EncodeToString(digest[:])
}

func parseLegacyMigrationRecord(contents string) (int64, string, string, bool) {
	matches := legacyMigrationRecordPattern.FindStringSubmatch(contents)
	if len(matches) != 4 {
		return 0, "", "", false
	}
	version, err := strconv.ParseInt(matches[1], 10, 64)
	if err != nil || version <= 0 {
		return 0, "", "", false
	}
	return version, strings.ReplaceAll(matches[2], "''", "'"), matches[3], true
}

// stripOuterTransaction lets the runner own the transaction. Existing SQL
// files contain BEGIN/COMMIT for safe direct psql bootstrap; nested transaction
// commands are not valid when the runner executes the file in *sql.Tx.
func stripOuterTransaction(contents string) string {
	contents = leadingBeginPattern.ReplaceAllString(contents, "")
	contents = trailingCommitPattern.ReplaceAllString(contents, ";")
	return strings.TrimSpace(contents)
}

// sqlMigrationDatabase adapts the project's database/sql PostgreSQL connection
// to the narrow migration seam above.
type sqlMigrationDatabase struct{ db *sql.DB }

type sqlMigrationTransaction struct{ tx *sql.Tx }

type sqlMigrationRows struct{ rows *sql.Rows }

func newSQLMigrationDatabase(db DB) (MigrationDatabase, bool) {
	switch value := db.(type) {
	case SQLDB:
		if value.DB == nil {
			return nil, false
		}
		return sqlMigrationDatabase{db: value.DB}, true
	case *SQLDB:
		if value == nil || value.DB == nil {
			return nil, false
		}
		return sqlMigrationDatabase{db: value.DB}, true
	default:
		return nil, false
	}
}

func (d sqlMigrationDatabase) PingContext(ctx context.Context) error { return d.db.PingContext(ctx) }
func (d sqlMigrationDatabase) Close() error                          { return d.db.Close() }
func (d sqlMigrationDatabase) BeginMigration(ctx context.Context) (MigrationTransaction, error) {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	return sqlMigrationTransaction{tx: tx}, nil
}

func (tx sqlMigrationTransaction) AdvisoryLock(ctx context.Context) error {
	_, err := tx.tx.ExecContext(ctx, migrationAdvisoryLockSQL)
	return err
}

func (tx sqlMigrationTransaction) EnsureSchemaMigrations(ctx context.Context) error {
	_, err := tx.tx.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version BIGINT PRIMARY KEY,
		name TEXT NOT NULL,
		checksum TEXT NOT NULL,
		applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
	)`)
	return err
}

func (tx sqlMigrationTransaction) AppliedMigrations(ctx context.Context) ([]MigrationRecord, error) {
	rows, err := tx.tx.QueryContext(ctx, `SELECT version, name, checksum FROM schema_migrations ORDER BY version`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []MigrationRecord
	for rows.Next() {
		var record MigrationRecord
		if err := rows.Scan(&record.Version, &record.Name, &record.Checksum); err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return records, nil
}

func (tx sqlMigrationTransaction) ExecuteMigration(ctx context.Context, contents string) error {
	_, err := tx.tx.ExecContext(ctx, contents)
	return err
}

func (tx sqlMigrationTransaction) InsertMigration(ctx context.Context, record MigrationRecord) error {
	_, err := tx.tx.ExecContext(ctx, `INSERT INTO schema_migrations (version, name, checksum) VALUES ($1, $2, $3)`, record.Version, record.Name, record.Checksum)
	return err
}

func (tx sqlMigrationTransaction) UpdateMigrationChecksum(ctx context.Context, version int64, checksum string) error {
	_, err := tx.tx.ExecContext(ctx, `UPDATE schema_migrations SET checksum = $1 WHERE version = $2`, checksum, version)
	return err
}

func (tx sqlMigrationTransaction) Commit() error   { return tx.tx.Commit() }
func (tx sqlMigrationTransaction) Rollback() error { return tx.tx.Rollback() }

// ErrMigrationsNotImplemented and PlaceholderMigrationRunner are retained for
// callers that explicitly test the old platform-only skeleton. Production
// startup uses SQLMigrationRunner instead.
var ErrMigrationsNotImplemented = errors.New("database migrations are not implemented in the platform skeleton")

type PlaceholderMigrationRunner struct{}

func (PlaceholderMigrationRunner) Run(context.Context) error { return ErrMigrationsNotImplemented }
