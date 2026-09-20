package familypostgres

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/momobox/backend/internal/family"
	"github.com/momobox/backend/internal/store/common"
)

func (r *Repository) Create(ctx context.Context, invite family.Invite) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO family_invites
			(id, family_id, created_by_user_id, code_hash, expires_at,
			 max_uses, used_count, created_at)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::bytea, $5, $6, $7, $8)`,
		invite.ID, invite.FamilyID, invite.CreatedBy, []byte(invite.CodeHash),
		invite.ExpiresAt, invite.MaxUses, invite.UsedCount, invite.CreatedAt)
	if common.HasSQLState(err, common.SQLStateUniqueViolation) {
		return &family.ServiceError{Code: family.CodeConflict, Message: "invite already exists", Cause: err}
	}
	return mapFamilyWriteError(err)
}

const findInviteByHashSQL = `
SELECT id::text, family_id::text, code_hash, expires_at, max_uses,
       used_count, created_by_user_id::text, created_at
FROM family_invites
WHERE code_hash = $1::bytea
  AND revoked_at IS NULL
  AND deleted_at IS NULL
ORDER BY created_at DESC, id
LIMIT 2`

func (r *Repository) FindByHash(ctx context.Context, codeHash string) (family.Invite, error) {
	rows, err := r.db.QueryContext(ctx, findInviteByHashSQL, []byte(codeHash))
	if err != nil {
		return family.Invite{}, err
	}
	defer rows.Close()
	invites, err := scanInvites(rows)
	if err != nil {
		return family.Invite{}, err
	}
	if len(invites) == 0 {
		return family.Invite{}, sql.ErrNoRows
	}
	if len(invites) > 1 {
		return family.Invite{}, &family.ServiceError{Code: family.CodeConflict, Message: "invite hash is ambiguous across families"}
	}
	return invites[0], nil
}

func (r *Repository) JoinWithInvite(ctx context.Context, codeHash, userID string, now time.Time) (family.Family, family.Membership, error) {
	var joinedFamily family.Family
	var joinedMembership family.Membership
	err := common.WithTx(ctx, r.db, nil, func(tx *sql.Tx) error {
		invite, err := findInviteForUpdate(ctx, tx, codeHash)
		if err != nil {
			return err
		}
		if !invite.ExpiresAt.After(now) {
			return &family.ServiceError{Code: family.CodeInviteExpired, Message: "invite code has expired"}
		}
		if invite.UsedCount >= invite.MaxUses {
			return &family.ServiceError{Code: family.CodeInviteExhausted, Message: "invite code has no remaining uses"}
		}
		if err := tx.QueryRowContext(ctx, `
			SELECT id::text, name, created_at
			FROM families
			WHERE id = $1::uuid AND deleted_at IS NULL
			FOR SHARE`, invite.FamilyID).
			Scan(&joinedFamily.ID, &joinedFamily.Name, &joinedFamily.CreatedAt); err != nil {
			return err
		}

		var existingRole family.Role
		var existingJoinedAt time.Time
		var deletedAt sql.NullTime
		err = tx.QueryRowContext(ctx, `
			SELECT role, joined_at, deleted_at
			FROM family_members
			WHERE family_id = $1::uuid AND user_id = $2::uuid
			FOR UPDATE`, invite.FamilyID, userID).
			Scan(&existingRole, &existingJoinedAt, &deletedAt)
		switch {
		case err == nil && !deletedAt.Valid:
			joinedMembership = family.Membership{
				FamilyID: invite.FamilyID, UserID: userID,
				Role: existingRole, JoinedAt: existingJoinedAt,
			}
			return nil
		case err == nil && deletedAt.Valid:
			_, err = tx.ExecContext(ctx, `
				UPDATE family_members
				SET role = 'member', joined_at = $3, deleted_at = NULL
				WHERE family_id = $1::uuid AND user_id = $2::uuid`, invite.FamilyID, userID, now)
		case errors.Is(err, sql.ErrNoRows):
			_, err = tx.ExecContext(ctx, `
				INSERT INTO family_members (family_id, user_id, role, joined_at)
				VALUES ($1::uuid, $2::uuid, 'member', $3)`, invite.FamilyID, userID, now)
		default:
			return err
		}
		if err != nil {
			return mapFamilyWriteError(err)
		}

		result, err := tx.ExecContext(ctx, `
			UPDATE family_invites
			SET used_count = used_count + 1
			WHERE id = $1::uuid
			  AND family_id = $2::uuid
			  AND revoked_at IS NULL
			  AND deleted_at IS NULL
			  AND expires_at > $3
			  AND used_count < max_uses`, invite.ID, invite.FamilyID, now)
		if err != nil {
			return err
		}
		count, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if count == 0 {
			return &family.ServiceError{Code: family.CodeInviteExhausted, Message: "invite code is no longer redeemable"}
		}
		joinedMembership = family.Membership{
			FamilyID: invite.FamilyID, UserID: userID,
			Role: family.RoleMember, JoinedAt: now,
		}
		return nil
	})
	return joinedFamily, joinedMembership, err
}

func findInviteForUpdate(ctx context.Context, tx *sql.Tx, codeHash string) (family.Invite, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT id::text, family_id::text, code_hash, expires_at, max_uses,
		       used_count, created_by_user_id::text, created_at
		FROM family_invites
		WHERE code_hash = $1::bytea
		  AND revoked_at IS NULL
		  AND deleted_at IS NULL
		ORDER BY created_at DESC, id
		LIMIT 2
		FOR UPDATE`, []byte(codeHash))
	if err != nil {
		return family.Invite{}, err
	}
	defer rows.Close()
	invites, err := scanInvites(rows)
	if err != nil {
		return family.Invite{}, err
	}
	if len(invites) == 0 {
		return family.Invite{}, sql.ErrNoRows
	}
	if len(invites) > 1 {
		return family.Invite{}, &family.ServiceError{Code: family.CodeConflict, Message: "invite hash is ambiguous across families"}
	}
	return invites[0], nil
}

type inviteRows interface {
	Next() bool
	Scan(...any) error
	Err() error
}

func scanInvites(rows inviteRows) ([]family.Invite, error) {
	invites := make([]family.Invite, 0, 2)
	for rows.Next() {
		var invite family.Invite
		var codeHash []byte
		if err := rows.Scan(&invite.ID, &invite.FamilyID, &codeHash, &invite.ExpiresAt,
			&invite.MaxUses, &invite.UsedCount, &invite.CreatedBy, &invite.CreatedAt); err != nil {
			return nil, err
		}
		invite.CodeHash = string(codeHash)
		invites = append(invites, invite)
	}
	return invites, rows.Err()
}

var _ family.InviteRepository = (*Repository)(nil)
var _ family.FamilyJoinRepository = (*Repository)(nil)
