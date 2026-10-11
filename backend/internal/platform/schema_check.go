package platform

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

var ErrMissingAppliedMigration = errors.New("database is missing a required migration")

// CheckMigrationSchema compares the immutable migration ledger with this
// image's files. It does not migrate, repair checksums, or create the ledger.
// This proves recorded schema identity, not full data integrity or restore epoch.
func CheckMigrationSchema(ctx context.Context, directory string, read func(context.Context) ([]MigrationRecord, error)) error {
	files, err := loadMigrationFiles(directory)
	if err != nil {
		return err
	}
	if read == nil {
		return errors.New("schema reader is not configured")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	records, err := read(ctx)
	if err != nil {
		return fmt.Errorf("read migration schema: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	known := make(map[int64]migrationFile, len(files))
	for _, file := range files {
		known[file.version] = file
	}
	seen := make(map[int64]bool, len(records))
	for _, record := range records {
		file, ok := known[record.Version]
		if !ok {
			return fmt.Errorf("%w: version %d", ErrUnknownAppliedMigration, record.Version)
		}
		if seen[record.Version] {
			return fmt.Errorf("%w: recorded version %d", ErrDuplicateMigrationVersion, record.Version)
		}
		if err := validateMigrationRecord(record, file); err != nil {
			return err
		}
		seen[record.Version] = true
	}
	for _, file := range files {
		if !seen[file.version] {
			return fmt.Errorf("%w: %s", ErrMissingAppliedMigration, file.name)
		}
	}
	return nil
}

// ReadMigrationSchema uses one bounded read-only snapshot and always closes it.
// In particular, a missing schema_migrations table must fail rather than create
// a new table and accidentally bless a restore or an uninitialized database.
func ReadMigrationSchema(ctx context.Context, db *sql.DB) ([]MigrationRecord, error) {
	if db == nil {
		return nil, errors.New("database is not configured")
	}
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true, Isolation: sql.LevelRepeatableRead})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()
	rows, err := tx.QueryContext(ctx, `SELECT version, name, checksum FROM schema_migrations ORDER BY version`)
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
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return records, nil
}
