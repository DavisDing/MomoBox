package familypostgres

import (
	"strings"
	"testing"
)

func TestCurrentFamilyUsesExplicitUserSelectionAndActiveMembership(t *testing.T) {
	for _, fragment := range []string{
		"u.current_family_id",
		"fm.user_id = u.id",
		"fm.deleted_at IS NULL",
		"f.deleted_at IS NULL",
	} {
		if !strings.Contains(findCurrentForUserSQL, fragment) {
			t.Fatalf("current family SQL missing guard %q", fragment)
		}
	}
}

func TestInviteLookupDoesNotReturnRevokedOrDeletedRows(t *testing.T) {
	for _, fragment := range []string{"code_hash = $1::bytea", "revoked_at IS NULL", "deleted_at IS NULL", "LIMIT 2"} {
		if !strings.Contains(findInviteByHashSQL, fragment) {
			t.Fatalf("invite SQL missing guard %q", fragment)
		}
	}
}
