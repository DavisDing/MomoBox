package authpostgres

import (
	"context"
	"database/sql"
	"errors"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/store/common"
)

type UserRepository struct{ db *sql.DB }

func NewUserRepository(db *sql.DB) *UserRepository { return &UserRepository{db: db} }

func (r *UserRepository) Count(ctx context.Context) (int, error) {
	var count int
	err := r.db.QueryRowContext(ctx, `SELECT count(*) FROM users WHERE deleted_at IS NULL`).Scan(&count)
	return count, err
}

func (r *UserRepository) FindByEmail(ctx context.Context, normalizedEmail string) (auth.StoredUser, error) {
	return scanStoredUser(r.db.QueryRowContext(ctx, `
		SELECT id::text, email, nickname, password_hash
		FROM users
		WHERE lower(email) = lower($1) AND deleted_at IS NULL`, normalizedEmail))
}

func (r *UserRepository) FindByID(ctx context.Context, userID string) (auth.StoredUser, error) {
	return scanStoredUser(r.db.QueryRowContext(ctx, `
		SELECT id::text, email, nickname, password_hash
		FROM users
		WHERE id = $1::uuid AND deleted_at IS NULL`, userID))
}

func (r *UserRepository) Create(ctx context.Context, user auth.StoredUser) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO users (id, email, nickname, password_hash)
		VALUES ($1::uuid, lower($2), $3, $4)`, user.ID, user.Email, user.Nickname, user.PasswordHash)
	if common.HasSQLState(err, common.SQLStateUniqueViolation) {
		return &auth.ServiceError{Code: auth.CodeEmailAlreadyExists, Message: "email already exists", Cause: err}
	}
	return err
}

type rowScanner interface{ Scan(...any) error }

func scanStoredUser(row rowScanner) (auth.StoredUser, error) {
	var stored auth.StoredUser
	err := row.Scan(&stored.ID, &stored.Email, &stored.Nickname, &stored.PasswordHash)
	if errors.Is(err, sql.ErrNoRows) {
		return auth.StoredUser{}, sql.ErrNoRows
	}
	return stored, err
}

var _ auth.UserRepository = (*UserRepository)(nil)
