package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/platform"
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

type catalogTransport func(*http.Request) (*http.Response, error)

func (f catalogTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAIModelCatalogFailureCodeAndSafeDiagnosticLog(t *testing.T) {
	for _, scenario := range []struct {
		code           string
		upstream, want int
	}{
		{"AI_MODELS_AUTH_FAILED", 401, 502},
		{"AI_MODELS_NOT_FOUND", 404, 502},
		{"AI_MODELS_TIMEOUT", 0, 504},
		{"AI_MODELS_UNREACHABLE", -1, 502},
		{"AI_NOT_CONFIGURED", -2, 503},
	} {
		t.Run(scenario.code, func(t *testing.T) {
			var logs bytes.Buffer
			previous := slog.Default()
			slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
			t.Cleanup(func() { slog.SetDefault(previous) })
			config := processing.AIConfig{Endpoints: []processing.AIEndpoint{{Endpoint: "http://private-gateway/v1", Key: "server-secret"}}, Client: &http.Client{Transport: catalogTransport(func(r *http.Request) (*http.Response, error) {
				if scenario.upstream == 0 {
					return nil, context.DeadlineExceeded
				}
				if scenario.upstream == -1 {
					return nil, errors.New("server-secret http://private-gateway connection refused")
				}
				return &http.Response{StatusCode: scenario.upstream, Body: io.NopCloser(strings.NewReader("server-secret http://private-gateway upstream error"))}, nil
			})}}
			if scenario.upstream == -2 {
				config = processing.AIConfig{}
			}
			handler := NewRouter(Dependencies{Processing: processing.New(nil, config), Verifier: testVerifier{claims: auth.AccessTokenClaims{UserID: "user", FamilyID: "family", DeviceID: "device", ExpiresAt: time.Now().Add(time.Hour)}}})
			request := httptest.NewRequest(http.MethodGet, "/api/v1/ai/models", nil)
			request.Header.Set("Authorization", "Bearer token")
			response := httptest.NewRecorder()
			platform.RequestIDMiddleware(handler).ServeHTTP(response, request)
			if response.Code != scenario.want || !strings.Contains(response.Body.String(), scenario.code) {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
			requestID := response.Header().Get("X-Request-ID")
			if requestID == "" || !strings.Contains(response.Body.String(), requestID) || !strings.Contains(logs.String(), "request_id="+requestID) {
				t.Fatalf("request diagnostic is not correlated: body=%s log=%s", response.Body.String(), logs.String())
			}
			if !strings.Contains(logs.String(), "ai_models_lookup") || !strings.Contains(logs.String(), "result="+scenario.code) {
				t.Fatalf("missing diagnostic: %s", logs.String())
			}
			for _, output := range []string{response.Body.String(), logs.String()} {
				for _, secret := range []string{"server-secret", "private-gateway", "upstream error", "connection refused", "Bearer token"} {
					if strings.Contains(output, secret) {
						t.Fatalf("leaked upstream diagnostic: %s", output)
					}
				}
			}
		})
	}
}
