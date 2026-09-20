package common

import (
	"errors"
	"fmt"
	"testing"
)

type stateError string

func (e stateError) Error() string    { return string(e) }
func (e stateError) SQLState() string { return string(e) }

func TestHasSQLStateFindsWrappedDriverError(t *testing.T) {
	err := fmt.Errorf("insert user: %w", stateError(SQLStateUniqueViolation))
	if !HasSQLState(err, SQLStateUniqueViolation) {
		t.Fatal("expected wrapped SQLSTATE to be detected")
	}
	if HasSQLState(errors.New("plain error"), SQLStateUniqueViolation) {
		t.Fatal("plain errors must not be classified as PostgreSQL errors")
	}
}
