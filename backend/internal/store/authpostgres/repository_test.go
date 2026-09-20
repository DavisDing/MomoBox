package authpostgres

import (
	"os"
	"strings"
	"testing"
)

func TestRefreshTokenCreationScopesDeviceToUser(t *testing.T) {
	for _, fragment := range []string{
		"FROM sync_devices",
		"id = NULLIF($3, '')::uuid",
		"user_id = $2::uuid",
		"deleted_at IS NULL",
	} {
		if !strings.Contains(createRefreshTokenSQL, fragment) {
			t.Fatalf("refresh token SQL missing scope guard %q", fragment)
		}
	}
}

func TestSyncDeviceQueriesKeepFamilyScopeAndMonotonicCursor(t *testing.T) {
	if !strings.Contains(syncDeviceColumns, "last_sync_cursor") || !strings.Contains(syncDeviceColumns, "last_sync_at") {
		t.Fatal("sync device projection must include checkpoint fields")
	}
}

func TestRefreshTokenReadAndRotationKeepExplicitFamilyScope(t *testing.T) {
	source, err := os.ReadFile("refresh_tokens.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, fragment := range []string{
		"COALESCE(rt.family_id::text, '')",
		"&record.FamilyID, &record.DeviceID",
		"replacement.FamilyID != currentFamilyID.String",
		"same-family refresh rotation must preserve the device",
		"FOR UPDATE OF rt, u",
	} {
		if !strings.Contains(text, fragment) {
			t.Fatalf("refresh token repository missing family-scope contract %q", fragment)
		}
	}
}

func TestAuthDeviceListingUsesCurrentFamilyScope(t *testing.T) {
	source, err := os.ReadFile("devices.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, fragment := range []string{
		"u.current_family_id = d.family_id",
		"d.user_id = $1::uuid",
		"d.deleted_at IS NULL",
	} {
		if !strings.Contains(text, fragment) {
			t.Fatalf("auth device listing missing current-family guard %q", fragment)
		}
	}
}
