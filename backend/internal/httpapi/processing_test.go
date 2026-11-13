package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/processing"
)

func TestAIModelCatalogRequiresFamilyDeviceAndReturnsAliases(t *testing.T) {
	for _, scenario := range []struct {
		name, family, device string
		authenticated        bool
		status               int
	}{
		{name: "anonymous", status: 401},
		{name: "no household", authenticated: true, status: 403},
		{name: "no device", family: "family", authenticated: true, status: 403},
		{name: "family device", family: "family", device: "phone", authenticated: true, status: 200},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			service := processing.New(nil, processing.AIConfig{
				Endpoints:     []processing.AIEndpoint{{Endpoint: "http://private-gateway/v1", Key: "server-secret", Model: "family-fast"}},
				AllowedModels: []string{"family-fast", "family-smart"},
			})
			handler := NewRouter(Dependencies{Processing: service, Verifier: testVerifier{claims: auth.AccessTokenClaims{
				UserID: "user", FamilyID: scenario.family, DeviceID: scenario.device, ExpiresAt: time.Now().Add(time.Hour),
			}}})
			request := httptest.NewRequest(http.MethodGet, "/api/v1/ai/models", nil)
			if scenario.authenticated {
				request.Header.Set("Authorization", "Bearer token")
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != scenario.status {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
			if strings.Contains(response.Body.String(), "server-secret") || strings.Contains(response.Body.String(), "private-gateway") {
				t.Fatal("catalog leaked NAS configuration")
			}
			if response.Code == 200 {
				var catalog struct {
					Models []processing.AIModel `json:"models"`
				}
				if err := json.Unmarshal(response.Body.Bytes(), &catalog); err != nil || len(catalog.Models) != 2 || !catalog.Models[0].Default || catalog.Models[1].ID != "family-smart" {
					t.Fatalf("unexpected catalog: %s", response.Body.String())
				}
			}
		})
	}
}

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
