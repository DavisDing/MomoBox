package homeassistant

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"
)

var applianceRunIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$`)

// NormalizeHAState converts the small set of HA states used by the linkage
// adapter to the two domain states understood by the rules engine. Unknown
// states are rejected rather than guessed, so an arbitrary HA event cannot
// accidentally create a consumable deduction.
func NormalizeHAState(value string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "running", "active", "on":
		return "running", nil
	case "completed", "complete", "finished", "off":
		return "completed", nil
	default:
		return "", fmt.Errorf("unsupported Home Assistant appliance state %q", value)
	}
}

// ValidateApplianceRunID requires the producer to provide a stable run token.
// The token is intentionally opaque, but bounded and free of whitespace or
// control characters because it is used as an idempotency key in PostgreSQL.
func ValidateApplianceRunID(value string) error {
	if !applianceRunIDPattern.MatchString(strings.TrimSpace(value)) {
		return fmt.Errorf("appliance_run_id must be 1-200 characters of letters, numbers, '.', '_' , ':' or '-'")
	}
	return nil
}

// NormalizeHAEvent validates the event envelope and canonicalizes state before
// it reaches persistence. The run ID may be supplied explicitly or in the
// event attributes emitted by a HA event adapter; accepting neither is an
// error. No timestamp or run ID is generated server-side because doing so
// would break duplicate delivery handling.
func NormalizeHAEvent(event HAEvent) (HAEvent, error) {
	event.IntegrationID = strings.TrimSpace(event.IntegrationID)
	event.EntityID = strings.TrimSpace(event.EntityID)
	event.ApplianceRunID = strings.TrimSpace(event.ApplianceRunID)
	event.Domain = strings.ToLower(strings.TrimSpace(event.Domain))
	if event.ApplianceRunID == "" && event.Attributes != nil {
		if value, ok := event.Attributes["appliance_run_id"].(string); ok {
			event.ApplianceRunID = strings.TrimSpace(value)
		}
	}
	if event.IntegrationID == "" || event.EntityID == "" {
		return HAEvent{}, fmt.Errorf("integration_id and entity_id are required")
	}
	if err := ValidateApplianceRunID(event.ApplianceRunID); err != nil {
		return HAEvent{}, err
	}
	state, err := NormalizeHAState(event.State)
	if err != nil {
		return HAEvent{}, err
	}
	event.State = state
	if event.PreviousState != "" {
		if previous, previousErr := NormalizeHAState(event.PreviousState); previousErr == nil {
			event.PreviousState = previous
		} else {
			event.PreviousState = strings.ToLower(strings.TrimSpace(event.PreviousState))
		}
	}
	return event, nil
}

// TrustedEventContext is for a server-side adapter after authenticating the
// integration. HTTP request fields and user bearer claims never populate it.
type trustedEventKey struct{}
type trustedEventSource struct{ familyID, integrationID string }

func TrustedEventContext(ctx context.Context, familyID, integrationID string) context.Context {
	return context.WithValue(ctx, trustedEventKey{}, trustedEventSource{familyID, integrationID})
}
func validateTrustedEvent(ctx context.Context, actor Actor, event HAEvent, now time.Time) error {
	source, ok := ctx.Value(trustedEventKey{}).(trustedEventSource)
	if !ok || source.familyID != actor.FamilyID || source.integrationID != event.IntegrationID {
		return businessError(CodeForbidden, "Home Assistant events require a trusted integration adapter", nil)
	}
	if event.OccurredAt.IsZero() || event.OccurredAt.Before(now.Add(-5*time.Minute)) || event.OccurredAt.After(now.Add(time.Minute)) {
		return businessError(CodeInvalidArgument, "Home Assistant event timestamp is outside the accepted delivery window", nil)
	}
	return nil
}
