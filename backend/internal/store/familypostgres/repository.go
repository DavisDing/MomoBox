package familypostgres

import (
	"context"
	"database/sql"
	"errors"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/family"
	"github.com/momobox/backend/internal/store/common"
)

// Repository implements all family persistence ports over one database. Every
// resource read is constrained by family_id or by users.current_family_id.
type Repository struct{ db *sql.DB }

func NewRepository(db *sql.DB) *Repository { return &Repository{db: db} }

func (r *Repository) CreateWithOwner(ctx context.Context, value family.Family, owner family.Membership) error {
	if value.ID != owner.FamilyID || owner.Role != family.RoleOwner {
		return &family.ServiceError{Code: family.CodeValidation, Message: "owner membership does not match family"}
	}
	return common.WithTx(ctx, r.db, nil, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO families (id, name, created_by_user_id, created_at)
			VALUES ($1::uuid, $2, $3::uuid, $4)`, value.ID, value.Name, owner.UserID, value.CreatedAt)
		if err != nil {
			return mapFamilyWriteError(err)
		}
		_, err = tx.ExecContext(ctx, `
			INSERT INTO family_members (family_id, user_id, role, joined_at)
			VALUES ($1::uuid, $2::uuid, $3, $4)`, owner.FamilyID, owner.UserID, owner.Role, owner.JoinedAt)
		return mapFamilyWriteError(err)
	})
}

func (r *Repository) FindByID(ctx context.Context, familyID string) (family.Family, error) {
	var value family.Family
	err := r.db.QueryRowContext(ctx, `
		SELECT id::text, name, created_at
		FROM families
		WHERE id = $1::uuid AND deleted_at IS NULL`, familyID).
		Scan(&value.ID, &value.Name, &value.CreatedAt)
	return value, err
}

const findCurrentForUserSQL = `
SELECT f.id::text, f.name, f.created_at, fm.user_id::text, fm.role, fm.joined_at
FROM users AS u
JOIN family_members AS fm
  ON fm.family_id = u.current_family_id
 AND fm.user_id = u.id
 AND fm.deleted_at IS NULL
JOIN families AS f
  ON f.id = fm.family_id
 AND f.deleted_at IS NULL
WHERE u.id = $1::uuid
  AND u.deleted_at IS NULL`

func (r *Repository) FindCurrentForUser(ctx context.Context, userID string) (family.Family, family.Membership, error) {
	var value family.Family
	var membership family.Membership
	err := r.db.QueryRowContext(ctx, findCurrentForUserSQL, userID).Scan(
		&value.ID, &value.Name, &value.CreatedAt,
		&membership.UserID, &membership.Role, &membership.JoinedAt,
	)
	membership.FamilyID = value.ID
	return value, membership, err
}

// SetCurrentForUser requires the selected family membership to be active. The
// users.current_family_id column is supplied by the follow-up schema migration.
func (r *Repository) SetCurrentForUser(ctx context.Context, userID, familyID string) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE users AS u
		SET current_family_id = fm.family_id,
		    updated_at = CURRENT_TIMESTAMP
		FROM family_members AS fm
		JOIN families AS f ON f.id = fm.family_id AND f.deleted_at IS NULL
		WHERE u.id = $1::uuid
		  AND u.deleted_at IS NULL
		  AND fm.family_id = $2::uuid
		  AND fm.user_id = u.id
		  AND fm.deleted_at IS NULL`, userID, familyID)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return &family.ServiceError{Code: family.CodeNotFound, Message: "active family membership was not found"}
	}
	return nil
}

func (r *Repository) Find(ctx context.Context, familyID, userID string) (family.Membership, error) {
	var membership family.Membership
	err := r.db.QueryRowContext(ctx, `
		SELECT family_id::text, user_id::text, role, joined_at
		FROM family_members
		WHERE family_id = $1::uuid
		  AND user_id = $2::uuid
		  AND deleted_at IS NULL`, familyID, userID).
		Scan(&membership.FamilyID, &membership.UserID, &membership.Role, &membership.JoinedAt)
	return membership, err
}

func (r *Repository) List(ctx context.Context, familyID string) ([]family.FamilyMember, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT u.id::text, u.email, u.nickname, fm.role, fm.joined_at
		FROM family_members AS fm
		JOIN users AS u ON u.id = fm.user_id AND u.deleted_at IS NULL
		WHERE fm.family_id = $1::uuid AND fm.deleted_at IS NULL
		ORDER BY CASE fm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END,
		         fm.joined_at, u.id`, familyID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := make([]family.FamilyMember, 0)
	for rows.Next() {
		var member family.FamilyMember
		if err := rows.Scan(&member.ID, &member.Email, &member.Nickname, &member.Role, &member.JoinedAt); err != nil {
			return nil, err
		}
		members = append(members, member)
	}
	return members, rows.Err()
}

func (r *Repository) ListUserMemberships(ctx context.Context, userID string) ([]auth.FamilyMembership, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT fm.family_id::text, fm.role
		FROM family_members AS fm
		JOIN families AS f ON f.id = fm.family_id AND f.deleted_at IS NULL
		WHERE fm.user_id = $1::uuid AND fm.deleted_at IS NULL
		ORDER BY fm.joined_at, fm.family_id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	memberships := make([]auth.FamilyMembership, 0)
	for rows.Next() {
		var membership auth.FamilyMembership
		if err := rows.Scan(&membership.FamilyID, &membership.Role); err != nil {
			return nil, err
		}
		memberships = append(memberships, membership)
	}
	return memberships, rows.Err()
}

// CurrentUserMembership is the auth composition adapter used when issuing an
// access token. It returns false for an active user with no selected family.
func (r *Repository) CurrentUserMembership(ctx context.Context, userID string) (auth.FamilyMembership, bool, error) {
	var membership auth.FamilyMembership
	err := r.db.QueryRowContext(ctx, `
		SELECT fm.family_id::text, fm.role
		FROM users AS u
		JOIN family_members AS fm
		  ON fm.family_id = u.current_family_id
		 AND fm.user_id = u.id
		 AND fm.deleted_at IS NULL
		JOIN families AS f ON f.id = fm.family_id AND f.deleted_at IS NULL
		WHERE u.id = $1::uuid AND u.deleted_at IS NULL`, userID).
		Scan(&membership.FamilyID, &membership.Role)
	if errors.Is(err, sql.ErrNoRows) {
		return auth.FamilyMembership{}, false, nil
	}
	if err != nil {
		return auth.FamilyMembership{}, false, err
	}
	return membership, true, nil
}

func mapFamilyWriteError(err error) error {
	if err == nil {
		return nil
	}
	if common.HasSQLState(err, common.SQLStateUniqueViolation) {
		return &family.ServiceError{Code: family.CodeConflict, Message: "family resource already exists", Cause: err}
	}
	if common.HasSQLState(err, common.SQLStateForeignKeyViolation) || common.HasSQLState(err, common.SQLStateCheckViolation) {
		return &family.ServiceError{Code: family.CodeValidation, Message: "family resource violates persistence constraints", Cause: err}
	}
	return err
}

var _ family.FamilyRepository = (*Repository)(nil)
var _ family.MembershipRepository = (*Repository)(nil)
var _ auth.MembershipReader = (*Repository)(nil)
