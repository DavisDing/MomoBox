package authpostgres

import (
	"context"
	"database/sql"
	"errors"
	"github.com/momobox/backend/internal/family"
	"time"

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

func (r *UserRepository) CreateFirst(ctx context.Context, user auth.StoredUser) error {
	return common.WithTx(ctx, r.db, nil, func(tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(18473,2)`); err != nil {
			return err
		}
		var exists bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE deleted_at IS NULL)`).Scan(&exists); err != nil {
			return err
		}
		if exists {
			return &auth.ServiceError{Code: auth.CodeRegistrationClosed, Message: "invite required"}
		}
		_, err := tx.ExecContext(ctx, `INSERT INTO users(id,email,nickname,password_hash) VALUES($1::uuid,lower($2),$3,$4)`, user.ID, user.Email, user.Nickname, user.PasswordHash)
		return err
	})
}

func (r *UserRepository) CreateInvited(ctx context.Context, user auth.StoredUser, hash string, now time.Time) (string, error) {
	var familyID string
	err := common.WithTx(ctx, r.db, nil, func(tx *sql.Tx) error {
		var id string
		var expires time.Time
		var maxUses, used int
		rows, err := tx.QueryContext(ctx, `SELECT i.id::text,i.family_id::text,i.expires_at,i.max_uses,i.used_count
    FROM family_invites i JOIN families f ON f.id=i.family_id AND f.deleted_at IS NULL
    WHERE i.code_hash=$1::bytea AND i.revoked_at IS NULL AND i.deleted_at IS NULL LIMIT 2 FOR UPDATE OF i`, []byte(hash))
		if err != nil {
			return err
		}
		count := 0
		for rows.Next() {
			count++
			if err = rows.Scan(&id, &familyID, &expires, &maxUses, &used); err != nil {
				rows.Close()
				return err
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return err
		}
		if count != 1 {
			return &family.ServiceError{Code: family.CodeInviteInvalid, Message: "invite is invalid"}
		}
		var activeFamily string
		if err = tx.QueryRowContext(ctx, `SELECT id::text FROM families WHERE id=$1::uuid AND deleted_at IS NULL FOR SHARE`, familyID).Scan(&activeFamily); errors.Is(err, sql.ErrNoRows) {
			return &family.ServiceError{Code: family.CodeInviteInvalid, Message: "invite is invalid"}
		} else if err != nil {
			return err
		}
		if !expires.After(now) {
			return &family.ServiceError{Code: family.CodeInviteExpired, Message: "invite has expired"}
		}
		if used >= maxUses {
			return &family.ServiceError{Code: family.CodeInviteExhausted, Message: "invite has no remaining uses"}
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO users(id,email,nickname,password_hash) VALUES($1::uuid,lower($2),$3,$4)`, user.ID, user.Email, user.Nickname, user.PasswordHash)
		if common.HasSQLState(err, common.SQLStateUniqueViolation) {
			return &auth.ServiceError{Code: auth.CodeEmailAlreadyExists, Message: "email already exists"}
		}
		if err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO family_members(family_id,user_id,role,joined_at) VALUES($1::uuid,$2::uuid,'member',$3)`, familyID, user.ID, now); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, `UPDATE users SET current_family_id=$2::uuid WHERE id=$1::uuid`, user.ID, familyID); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `UPDATE family_invites SET used_count=used_count+1 WHERE id=$1::uuid`, id)
		return err
	})
	return familyID, err
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
