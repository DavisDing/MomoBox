package httpapi

import (
	syncdomain "github.com/momobox/backend/internal/sync"
	"net/http"
	"testing"
)

func TestConflictResolutionRetryErrorsAreNotServerFailures(t *testing.T) {
	for _, code := range []string{"CONFLICT_ALREADY_RESOLVED", "CONFLICT_ACTION_UNSUPPORTED", "IDEMPOTENCY_KEY_REUSE"} {
		got, _, _, status := mapServiceError(syncdomain.NewBusinessError(code, "request conflicts with current state", nil))
		if got != code || status != http.StatusConflict {
			t.Fatalf("%s mapped to %s/%d", code, got, status)
		}
	}
}

func TestSyncBusinessErrorsUseActionableHTTPStatuses(t *testing.T) {
	for code, want := range map[string]int{
		"BOOTSTRAP_CHECKPOINT_STALE": 409, "INVALID_CURSOR": 400, "INVALID_PRODUCT": 400,
		"INVALID_CATEGORY": 400, "INVALID_BATCH": 400, "DEPENDENCY_REQUIRED": 400, "UNSUPPORTED_ENTITY": 400,
		"INVENTORY_COMMAND_REQUIRED": 400, "INSUFFICIENT_STOCK": 409, "BATCH_UNAVAILABLE": 409,
		"HA_NOT_CONFIGURED": 503, "INVALID_AUTHORITATIVE_RESULT": 500,
	} {
		_, _, _, got := mapServiceError(syncdomain.NewBusinessError(code, "request failed", nil))
		if got != want {
			t.Fatalf("%s: %d, want %d", code, got, want)
		}
	}
}
