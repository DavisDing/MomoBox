package platform

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// DB is the minimal database contract needed by the platform layer. Keeping it
// small lets handlers and health checks use sql.DB, a test double, or a future
// transaction-aware repository without coupling the platform to an ORM.
type DB interface {
	PingContext(context.Context) error
	Close() error
}

type SQLDB struct{ *sql.DB }

func (db SQLDB) PingContext(ctx context.Context) error { return db.DB.PingContext(ctx) }
func (db SQLDB) Close() error                          { return db.DB.Close() }

type SQLDatabaseOpener func(driverName, dataSourceName string) (*sql.DB, error)

func openPostgresSQL(opener SQLDatabaseOpener, databaseURL string) (*sql.DB, error) {
	if opener == nil {
		return nil, errors.New("postgres opener is nil")
	}
	if databaseURL == "" {
		return nil, errors.New("database URL is empty")
	}
	db, err := opener("pgx", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("open postgres database: %w", err)
	}
	if db == nil {
		return nil, errors.New("postgres opener returned nil database")
	}
	return db, nil
}

// OpenPostgres uses database/sql and an injected opener. It is retained for
// platform callers and tests that depend only on the minimal DB contract.
func OpenPostgres(opener SQLDatabaseOpener, databaseURL string) (DB, error) {
	db, err := openPostgresSQL(opener, databaseURL)
	if err != nil {
		return nil, err
	}
	return SQLDB{DB: db}, nil
}

// OpenPostgresSQL is the production opener for composition roots that need the
// concrete *sql.DB transaction and query surface used by PostgreSQL adapters.
func OpenPostgresSQL(databaseURL string) (*sql.DB, error) {
	return openPostgresSQL(sql.Open, databaseURL)
}

func OpenPostgresDefault(databaseURL string) (DB, error) {
	return OpenPostgres(sql.Open, databaseURL)
}

type HealthChecker struct {
	DB      DB
	Timeout func() (context.Context, context.CancelFunc)
}

func (h HealthChecker) Check(ctx context.Context) error {
	if h.DB == nil {
		return errors.New("database is not configured")
	}
	if h.Timeout != nil {
		var cancel context.CancelFunc
		ctx, cancel = h.Timeout()
		defer cancel()
	}
	return h.DB.PingContext(ctx)
}
