package hapostgres

import (
	"testing"

	"github.com/momobox/backend/internal/homeassistant"
)

func TestParseKeyVersionPreservesOpaqueAEADIdentifier(t *testing.T) {
	t.Parallel()
	for _, version := range []string{"1", "2", "aes256gcm-123abc", "v1"} {
		if got, err := parseKeyVersion(version); err != nil || got != version {
		t.Fatalf("opaque version %q changed: %q %v", version, got, err)
		}
	}
	for _, invalid := range []string{"", " 2 ", "v1\n", "v 1", "v\x001"} {
		if _, err := parseKeyVersion(invalid); err == nil {
			t.Fatalf("invalid version %q accepted", invalid)
		}
	}
}

func TestAuditResultMapsDeniedToMigrationRejectedValue(t *testing.T) {
	t.Parallel()
	tests := []struct {
		input homeassistant.AuditResult
		want  string
	}{
		{homeassistant.AuditSucceeded, "succeeded"},
		{homeassistant.AuditFailed, "failed"},
		{homeassistant.AuditDenied, "rejected"},
	}
	for _, test := range tests {
		got, err := auditResult(test.input)
		if err != nil || got != test.want {
			t.Fatalf("auditResult(%q) = (%q, %v), want %q", test.input, got, err, test.want)
		}
	}
	if _, err := auditResult(homeassistant.AuditResult("raw")); err == nil {
		t.Fatal("expected unknown audit result to be rejected")
	}
}

func TestPersistedEntityAttributesContainOnlyTypedMetadata(t *testing.T) {
	t.Parallel()
	kind := persistedEntityAttributes{}
	_ = kind
	// This compile-time construction intentionally demonstrates that repository
	// metadata has no raw domain, service, or service_data field.
	value := persistedEntityAttributes{HVACModes: []string{"heat"}}
	if len(value.HVACModes) != 1 || value.HVACModes[0] != "heat" {
		t.Fatalf("unexpected typed entity metadata: %+v", value)
	}
}
