package authpostgres

import (
	"context"
	"database/sql"
	"github.com/momobox/backend/internal/auth"
)

// AccessAuthorizer rechecks current authorization for already signed claims.
// Roles in old JWTs never override current membership or device revocation.
type AccessAuthorizer struct{ db *sql.DB }

func NewAccessAuthorizer(db *sql.DB) *AccessAuthorizer { return &AccessAuthorizer{db: db} }
func (r *AccessAuthorizer) AuthorizeClaims(ctx context.Context, claims auth.AccessTokenClaims) (auth.AccessTokenClaims, error) {
	var role string
	err := r.db.QueryRowContext(ctx, `
SELECT fm.role FROM family_members fm
JOIN users u ON u.id = fm.user_id AND u.deleted_at IS NULL
JOIN families f ON f.id = fm.family_id AND f.deleted_at IS NULL
WHERE fm.family_id = $1::uuid AND fm.user_id = $2::uuid AND fm.deleted_at IS NULL
  AND fm.role IN ('owner', 'admin', 'member')
  AND (NULLIF($3, '') IS NULL OR EXISTS (
    SELECT 1 FROM sync_devices d WHERE d.id = NULLIF($3,'')::uuid
      AND d.family_id = fm.family_id AND d.user_id = fm.user_id
      AND d.revoked_at IS NULL AND d.deleted_at IS NULL
  ))`, claims.FamilyID, claims.UserID, claims.DeviceID).Scan(&role)
	if err != nil {
		return auth.AccessTokenClaims{}, &auth.ServiceError{Code: auth.CodeInvalidToken, Message: "current family membership or device is unavailable", Cause: err}
	}
	claims.Role = role
	return claims, nil
}
