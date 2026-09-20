package auth

import "time"

type RegistrationMode string

const (
	RegistrationFirstSetup RegistrationMode = "first_setup"
	RegistrationInviteOnly RegistrationMode = "invite_only"
	RegistrationOpen       RegistrationMode = "open"
)

type User struct {
	ID       string `json:"id"`
	Email    string `json:"email"`
	Nickname string `json:"nickname"`
}

// StoredUser is the repository representation. PasswordHash must never be
// returned by a DTO or logged by an adapter.
type StoredUser struct {
	User
	PasswordHash string
}

type FamilyMembership struct {
	FamilyID string `json:"family_id"`
	Role     string `json:"role"`
}

type SyncDevice struct {
	ID         string     `json:"id"`
	DeviceName string     `json:"device_name"`
	Platform   string     `json:"platform"`
	AppVersion string     `json:"app_version,omitempty"`
	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
}

type RefreshTokenRecord struct {
	ID         string
	TokenHash  string
	UserID     string
	FamilyID   string
	DeviceID   string
	ExpiresAt  time.Time
	CreatedAt  time.Time
	RevokedAt  *time.Time
	ReplacedBy string
}

type AccessTokenClaims struct {
	UserID    string
	FamilyID  string
	Role      string
	DeviceID  string
	IssuedAt  time.Time
	ExpiresAt time.Time
}

type Principal struct {
	UserID   string
	FamilyID string
	Role     string
	DeviceID string
}
