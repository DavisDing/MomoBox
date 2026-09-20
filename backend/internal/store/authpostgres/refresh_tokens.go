package authpostgres

import (
	"context"
	"database/sql"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/store/common"
)

type RefreshTokenRepository struct{ db *sql.DB }

func NewRefreshTokenRepository(db *sql.DB) *RefreshTokenRepository {
	return &RefreshTokenRepository{db: db}
}

func (r *RefreshTokenRepository) FindByHash(ctx context.Context, tokenHash string) (auth.RefreshTokenRecord, error) {
	return scanRefreshToken(r.db.QueryRowContext(ctx, `
		SELECT rt.id::text, rt.token_hash, rt.user_id::text,
		       COALESCE(rt.family_id::text, ''),
		       CASE WHEN rt.family_id = u.current_family_id THEN COALESCE(rt.device_id::text, '') ELSE '' END,
		       rt.expires_at, rt.created_at, rt.revoked_at,
		       COALESCE(rt.replaced_by_token_id::text, '')
		FROM refresh_tokens AS rt
		JOIN users AS u ON u.id = rt.user_id AND u.deleted_at IS NULL
		WHERE rt.token_hash = $1::bytea`, []byte(tokenHash)))
}

func (r *RefreshTokenRepository) Create(ctx context.Context, record auth.RefreshTokenRecord) error {
	result, err := r.db.ExecContext(ctx, createRefreshTokenSQL,
		record.ID, record.UserID, record.DeviceID, []byte(record.TokenHash), record.ExpiresAt, record.CreatedAt)
	if common.HasSQLState(err, common.SQLStateUniqueViolation) {
		return &auth.ServiceError{Code: auth.CodeConflict, Message: "refresh token already exists", Cause: err}
	}
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return &auth.ServiceError{Code: auth.CodeConflict, Message: "refresh token device is outside the current family"}
	}
	return nil
}

const createRefreshTokenSQL = `
WITH device_scope AS (
	SELECT d.id, d.family_id
	FROM sync_devices AS d
	JOIN users AS u ON u.id = $2::uuid AND u.current_family_id = d.family_id
	WHERE d.id = NULLIF($3, '')::uuid
	  AND d.user_id = $2::uuid
	  AND d.deleted_at IS NULL
	  AND d.revoked_at IS NULL
)
INSERT INTO refresh_tokens
	(id, user_id, family_id, device_id, token_hash, expires_at, created_at)
SELECT $1::uuid, $2::uuid, scope.family_id, scope.id, $4::bytea, $5, $6
FROM (SELECT 1) AS seed
LEFT JOIN device_scope AS scope ON TRUE
WHERE NULLIF($3, '') IS NULL OR scope.id IS NOT NULL`

func (r *RefreshTokenRepository) Rotate(ctx context.Context, oldHash string, replacement auth.RefreshTokenRecord, now time.Time) error {
	return common.WithTx(ctx, r.db, nil, func(tx *sql.Tx) error {
		var oldID, userID string
		var familyID, deviceID, currentFamilyID sql.NullString
		var revokedAt sql.NullTime
		err := tx.QueryRowContext(ctx, `
			SELECT rt.id::text, rt.user_id::text, rt.family_id::text,
			       rt.device_id::text, rt.revoked_at, u.current_family_id::text
			FROM refresh_tokens AS rt
			JOIN users AS u ON u.id = rt.user_id AND u.deleted_at IS NULL
			WHERE rt.token_hash = $1::bytea
			FOR UPDATE OF rt, u`, []byte(oldHash)).Scan(
			&oldID, &userID, &familyID, &deviceID, &revokedAt, &currentFamilyID,
		)
		if err != nil {
			return err
		}
		if revokedAt.Valid {
			return &auth.ServiceError{Code: auth.CodeRefreshRevoked, Message: "refresh token has been revoked"}
		}
		if replacement.UserID != userID || replacement.FamilyID != currentFamilyID.String {
			return &auth.ServiceError{Code: auth.CodeConflict, Message: "refresh token target family changed during rotation"}
		}

		var replacementFamilyID, replacementDeviceID any
		if replacement.DeviceID != "" {
			if !familyID.Valid || !deviceID.Valid ||
				replacement.FamilyID != familyID.String || replacement.DeviceID != deviceID.String {
				return &auth.ServiceError{Code: auth.CodeConflict, Message: "refresh token device scope changed during rotation"}
			}
			replacementFamilyID = familyID.String
			replacementDeviceID = deviceID.String
		} else {
			// MATCH FULL on (device_id, family_id) requires both values to be
			// NULL. Dropping an existing device is valid only when its family is
			// no longer the user's current family; same-family rotation preserves it.
			if deviceID.Valid && familyID.Valid && familyID.String == currentFamilyID.String {
				return &auth.ServiceError{Code: auth.CodeConflict, Message: "same-family refresh rotation must preserve the device"}
			}
			replacementFamilyID = nil
			replacementDeviceID = nil
		}
		_, err = tx.ExecContext(ctx, `
			INSERT INTO refresh_tokens
				(id, user_id, family_id, device_id, token_hash, expires_at, created_at)
			VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::bytea, $6, $7)`,
			replacement.ID, userID, replacementFamilyID, replacementDeviceID, []byte(replacement.TokenHash), replacement.ExpiresAt, replacement.CreatedAt)
		if common.HasSQLState(err, common.SQLStateUniqueViolation) {
			return &auth.ServiceError{Code: auth.CodeConflict, Message: "replacement refresh token already exists", Cause: err}
		}
		if err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `
			UPDATE refresh_tokens
			SET revoked_at = $2, last_used_at = $2, replaced_by_token_id = $3::uuid
			WHERE id = $1::uuid`, oldID, now, replacement.ID)
		return err
	})
}

func (r *RefreshTokenRepository) Revoke(ctx context.Context, tokenHash string, now time.Time) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE refresh_tokens
		SET revoked_at = COALESCE(revoked_at, $2), last_used_at = $2
		WHERE token_hash = $1::bytea`, []byte(tokenHash), now)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func scanRefreshToken(row rowScanner) (auth.RefreshTokenRecord, error) {
	var record auth.RefreshTokenRecord
	var tokenHash []byte
	var revokedAt sql.NullTime
	err := row.Scan(&record.ID, &tokenHash, &record.UserID, &record.FamilyID, &record.DeviceID,
		&record.ExpiresAt, &record.CreatedAt, &revokedAt, &record.ReplacedBy)
	if err != nil {
		return auth.RefreshTokenRecord{}, err
	}
	record.TokenHash = string(tokenHash)
	if revokedAt.Valid {
		value := revokedAt.Time.UTC()
		record.RevokedAt = &value
	}
	return record, nil
}

var _ auth.RefreshTokenRepository = (*RefreshTokenRepository)(nil)
