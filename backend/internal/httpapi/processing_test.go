package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/processing"
)

func TestProcessingRoutesRequireFamilySession(t *testing.T) {
	for _, path := range []string{"/api/v1/media/upload", "/api/v1/media/manual/search", "/api/v1/ai/analyze", "/api/v1/media/a/ocr", "/api/v1/media/a/delete", "/api/v1/media/a/reassign"} {
		for _, authenticated := range []bool{false, true} {
			h := NewRouter(Dependencies{Processing: processing.New(nil, processing.AIConfig{}), Verifier: testVerifier{claims: auth.AccessTokenClaims{UserID: "user", ExpiresAt: time.Now().Add(time.Hour)}}})
			request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{}`))
			request.Header.Set("Content-Type", "application/json")
			if authenticated {
				request.Header.Set("Authorization", "Bearer token")
			}
			response := httptest.NewRecorder()
			h.ServeHTTP(response, request)
			want := 401
			if authenticated {
				want = 403
			}
			if response.Code != want {
				t.Fatalf("%s auth=%v: %d %s", path, authenticated, response.Code, response.Body.String())
			}
		}
	}
}
func TestAIClientCannotSupplyEndpointOrKeys(t *testing.T) {
	h := NewRouter(Dependencies{Processing: processing.New(nil, processing.AIConfig{}), Verifier: testVerifier{claims: auth.AccessTokenClaims{UserID: "user", FamilyID: "family", DeviceID: "device", ExpiresAt: time.Now().Add(time.Hour)}}})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/ai/analyze", strings.NewReader(`{"endpoint":"http://arbitrary.local","api_key":"injected"}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer token")
	response := httptest.NewRecorder()
	h.ServeHTTP(response, request)
	if response.Code != 400 || strings.Contains(response.Body.String(), "injected") {
		t.Fatalf("untrusted destination accepted/leaked: %d %s", response.Code, response.Body.String())
	}
}
