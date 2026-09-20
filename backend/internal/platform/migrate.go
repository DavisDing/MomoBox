package platform

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var ErrNoMigrations = errors.New("no SQL migrations found")

// MigrationRunner executes versioned SQL files. Each file owns its transaction
// and advisory lock so the runner remains safe when invoked by two containers.
type MigrationRunner interface{ Run(context.Context) error }

type SQLMigrationRunner struct {
	DatabaseURL string
	Directory   string
	Open        func(string) (DB, error)
}

func (r SQLMigrationRunner) Run(ctx context.Context) error {
	if strings.TrimSpace(r.DatabaseURL) == "" {
		return errors.New("database URL is empty")
	}
	directory := r.Directory
	if strings.TrimSpace(directory) == "" {
		directory = "./migrations"
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return fmt.Errorf("read migrations directory: %w", err)
	}
	files := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
			files = append(files, filepath.Join(directory, entry.Name()))
		}
	}
	if len(files) == 0 {
		return ErrNoMigrations
	}
	sort.Strings(files)
	open := r.Open
	if open == nil {
		open = OpenPostgresDefault
	}
	db, err := open(r.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Close()
	if sqlDB, ok := db.(SQLDB); ok {
		if err := sqlDB.PingContext(ctx); err != nil {
			return fmt.Errorf("ping postgres: %w", err)
		}
	}
	for _, file := range files {
		contents, err := os.ReadFile(file)
		if err != nil {
			return fmt.Errorf("read migration %s: %w", file, err)
		}
		execDB, ok := db.(SQLDB)
		if !ok {
			return errors.New("migration runner requires SQLDB")
		}
		if _, err := execDB.ExecContext(ctx, string(contents)); err != nil {
			return fmt.Errorf("execute migration %s: %w", filepath.Base(file), err)
		}
	}
	return nil
}

// SQLDBExec is kept as a narrow test seam for future migration adapters.
type SQLDBExec interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

// ErrMigrationsNotImplemented and PlaceholderMigrationRunner are retained for
// callers that explicitly test the old platform-only skeleton. Production
// startup uses SQLMigrationRunner instead.
var ErrMigrationsNotImplemented = errors.New("database migrations are not implemented in the platform skeleton")

type PlaceholderMigrationRunner struct{}

func (PlaceholderMigrationRunner) Run(context.Context) error { return ErrMigrationsNotImplemented }
