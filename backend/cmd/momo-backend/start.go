package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/momobox/backend/internal/platform"
)

// The image uses start; serve remains available for maintenance workflows
// that apply migrations separately and require a read-only readiness gate.
func start(ctx context.Context) error {
	if strings.TrimSpace(os.Getenv("DATABASE_URL")) == "" {
		return errors.New("start requires DATABASE_URL")
	}
	cfg, err := platform.LoadConfig()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	fmt.Println("Checking database migrations; initializing an empty database or applying pending migrations.")
	migrationCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	err = (platform.SQLMigrationRunner{
		DatabaseURL:           cfg.DatabaseURL,
		Directory:             os.Getenv("MIGRATIONS_DIR"),
		RequireEmptyBootstrap: true,
	}).Run(migrationCtx)
	cancel()
	if err != nil {
		return startupMigrationError(err)
	}
	fmt.Println("Database migrations ready; starting server.")
	return serve(ctx)
}

func startupMigrationError(err error) error {
	for _, cause := range []error{
		platform.ErrUntrackedDatabase,
		platform.ErrMigrationHistoryGap,
		platform.ErrUnknownAppliedMigration,
		platform.ErrMigrationNameMismatch,
		platform.ErrMigrationChecksumMismatch,
		platform.ErrDuplicateMigrationVersion,
		platform.ErrInvalidMigrationFilename,
		platform.ErrNoMigrations,
		context.Canceled,
		context.DeadlineExceeded,
	} {
		if errors.Is(err, cause) {
			return fmt.Errorf("database startup stopped: %w", cause)
		}
	}
	// Connection and SQL errors may include credentials or application data.
	// Report the server error code without copying the DSN or raw message.
	var pgError *pgconn.PgError
	if errors.As(err, &pgError) {
		return fmt.Errorf("database initialization or migration failed (SQLSTATE %s); check database permissions and run migrate for details", pgError.Code)
	}
	return errors.New("database initialization or migration failed; check connectivity and migration files, then run migrate for details")
}
