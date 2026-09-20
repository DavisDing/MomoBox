package hapostgres

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/momobox/backend/internal/homeassistant"
)

// DB is the database/sql surface required by the Home Assistant repositories.
// *sql.DB satisfies this interface.
type DB interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
	BeginTx(context.Context, *sql.TxOptions) (*sql.Tx, error)
}

type querier interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func notFound(resource string, cause error) error {
	return &homeassistant.BusinessError{
		Code:    homeassistant.CodeNotFound,
		Message: resource + " was not found",
		Cause:   cause,
	}
}

func requireDB(db DB) error {
	if db == nil {
		return errors.New("home assistant postgres repository: database is nil")
	}
	return nil
}

func marshalJSON(value any) ([]byte, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode postgres JSON value: %w", err)
	}
	return encoded, nil
}

func rollback(tx *sql.Tx) {
	_ = tx.Rollback()
}
