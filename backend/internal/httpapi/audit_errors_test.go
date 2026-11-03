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
