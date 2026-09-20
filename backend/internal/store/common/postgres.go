package common

import "errors"

const (
	SQLStateUniqueViolation     = "23505"
	SQLStateForeignKeyViolation = "23503"
	SQLStateCheckViolation      = "23514"
	SQLStateSerialization       = "40001"
)

type sqlStateError interface {
	SQLState() string
}

// HasSQLState works with pgx/pgconn errors without coupling every repository
// to the concrete driver error type.
func HasSQLState(err error, state string) bool {
	var target sqlStateError
	return errors.As(err, &target) && target.SQLState() == state
}
