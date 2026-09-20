package auth

import (
	"context"
	"time"
)

type UserRepository interface {
	Count(ctx context.Context) (int, error)
	FindByEmail(ctx context.Context, normalizedEmail string) (StoredUser, error)
	FindByID(ctx context.Context, userID string) (StoredUser, error)
	Create(ctx context.Context, user StoredUser) error
}

type RefreshTokenRepository interface {
	// FindByHash receives only the deterministic hash; raw refresh tokens never
	// cross the repository boundary.
	FindByHash(ctx context.Context, tokenHash string) (RefreshTokenRecord, error)
	Create(ctx context.Context, record RefreshTokenRecord) error
	// Rotate must atomically revoke the old hash and create the replacement.
	Rotate(ctx context.Context, oldHash string, replacement RefreshTokenRecord, now time.Time) error
	Revoke(ctx context.Context, tokenHash string, now time.Time) error
}

type MembershipReader interface {
	ListUserMemberships(ctx context.Context, userID string) ([]FamilyMembership, error)
	CurrentUserMembership(ctx context.Context, userID string) (FamilyMembership, bool, error)
}

type DeviceReader interface {
	ListUserDevices(ctx context.Context, userID string) ([]SyncDevice, error)
	UpsertDevice(ctx context.Context, record DeviceRecord) error
}

type PasswordHasher interface {
	Hash(password string) (string, error)
	Compare(encodedHash, password string) error
}

type AccessTokenIssuer interface {
	Issue(claims AccessTokenClaims) (string, error)
	Verify(token string, now time.Time) (AccessTokenClaims, error)
}

type RandomTokenSource interface {
	RandomToken() (string, error)
}

type IDGenerator interface {
	NewID() (string, error)
}

type Clock interface {
	Now() time.Time
}
