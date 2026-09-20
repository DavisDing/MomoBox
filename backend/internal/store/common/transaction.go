package common

import (
	"context"
	"database/sql"
	"errors"
)

// Beginner is implemented by *sql.DB and keeps repositories on database/sql.
type Beginner interface {
	BeginTx(context.Context, *sql.TxOptions) (*sql.Tx, error)
}

// WithTx commits only when fn succeeds. A rollback after commit is harmless.
func WithTx(ctx context.Context, db Beginner, options *sql.TxOptions, fn func(*sql.Tx) error) (err error) {
	if db == nil {
		return errors.New("postgres transaction beginner is nil")
	}
	tx, err := db.BeginTx(ctx, options)
	if err != nil {
		return err
	}
	defer func() {
		if rollbackErr := tx.Rollback(); err == nil && rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) {
			err = rollbackErr
		}
	}()
	if err = fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}
