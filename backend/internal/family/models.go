package family

import "time"

type Role string

const (
	RoleOwner  Role = "owner"
	RoleAdmin  Role = "admin"
	RoleMember Role = "member"
)

type Family struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type Membership struct {
	FamilyID string    `json:"family_id"`
	UserID   string    `json:"user_id,omitempty"`
	Role     Role      `json:"role"`
	JoinedAt time.Time `json:"joined_at,omitempty"`
}

type UserSummary struct {
	ID       string `json:"id"`
	Email    string `json:"email"`
	Nickname string `json:"nickname"`
}

type FamilyMember struct {
	UserSummary
	Role     Role      `json:"role"`
	JoinedAt time.Time `json:"joined_at"`
}

type Invite struct {
	ID        string
	FamilyID  string
	CodeHash  string
	ExpiresAt time.Time
	MaxUses   int
	UsedCount int
	CreatedBy string
	CreatedAt time.Time
}

func (i Invite) RemainingUses() int {
	remaining := i.MaxUses - i.UsedCount
	if remaining < 0 {
		return 0
	}
	return remaining
}
