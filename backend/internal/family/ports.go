package family

import (
	"context"
	"time"
)

type IDGenerator interface{ NewID() (string, error) }
type CodeGenerator interface{ NewCode() (string, error) }
type Clock interface{ Now() time.Time }

type FamilyRepository interface {
	// CreateWithOwner is one logical operation: the family and owner membership
	// must be committed together by a persistence adapter.
	CreateWithOwner(ctx context.Context, family Family, owner Membership) error
	FindByID(ctx context.Context, familyID string) (Family, error)
	FindCurrentForUser(ctx context.Context, userID string) (Family, Membership, error)
	SetCurrentForUser(ctx context.Context, userID, familyID string) error
}

type MembershipRepository interface {
	Find(ctx context.Context, familyID, userID string) (Membership, error)
	List(ctx context.Context, familyID string) ([]FamilyMember, error)
}

type InviteRepository interface {
	Create(ctx context.Context, invite Invite) error
	FindByHash(ctx context.Context, codeHash string) (Invite, error)
}

// FamilyJoinRepository is the transaction boundary for invite redemption. A
// database adapter must validate expiry/uses and add the membership atomically
// so a failed join cannot consume an invite.
type FamilyJoinRepository interface {
	JoinWithInvite(ctx context.Context, codeHash, userID string, now time.Time) (Family, Membership, error)
}
