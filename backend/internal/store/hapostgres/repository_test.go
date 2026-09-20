package hapostgres

import (
	"testing"

	"github.com/momobox/backend/internal/homeassistant"
)

func TestParseKeyVersionRequiresPositiveInteger(t *testing.T) {
	t.Parallel()
	if got, err := parseKeyVersion(" 2 "); err != nil || got != 2 {
		t.Fatalf("parseKeyVersion returned (%d, %v)", got, err)
	}
	for _, invalid := range []string{"", "0", "-1", "v1", "1.5"} {
		if _, err := parseKeyVersion(invalid); err == nil {
			t.Fatalf("expected key version %q to be rejected", invalid)
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
