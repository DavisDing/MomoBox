package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/momobox/backend/internal/platform"
)

func TestStartRequiresDatabaseURLBeforeInitializingSecrets(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	if err := run(context.Background(), []string{"start"}); err == nil || err.Error() != "start requires DATABASE_URL" {
		t.Fatalf("start error = %v", err)
	}
}

func TestStartupMigrationErrorsPreserveSafeCausesWithoutLeakingDetails(t *testing.T) {
	for _, cause := range []error{
		platform.ErrUntrackedDatabase, platform.ErrUnknownAppliedMigration, platform.ErrMigrationHistoryGap,
		platform.ErrMigrationNameMismatch, platform.ErrMigrationChecksumMismatch,
		platform.ErrDuplicateMigrationVersion, context.Canceled, context.DeadlineExceeded,
	} {
		err := startupMigrationError(fmt.Errorf("private-data: %w", cause))
		if !errors.Is(err, cause) || strings.Contains(err.Error(), "private-data") {
			t.Fatalf("unsafe or lost startup cause: %v", err)
		}
	}
	for _, failure := range []error{
		errors.New("postgres://user:private-data@db/momobox"),
		&pgconn.PgError{Code: "42501", Message: "private-data", Detail: "secret row"},
	} {
		err := startupMigrationError(failure)
		if strings.Contains(err.Error(), "private-data") || strings.Contains(err.Error(), "secret row") {
			t.Fatalf("startup error leaked credentials or row data: %v", err)
		}
	}
	err := startupMigrationError(&pgconn.PgError{Code: "42501"})
	if !strings.Contains(err.Error(), "42501") {
		t.Fatalf("SQLSTATE missing from diagnostic: %v", err)
	}
}
