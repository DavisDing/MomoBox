package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
	homeassistant "github.com/momobox/backend/internal/homeassistant"
)

type contractHAVerifier struct { claims auth.AccessTokenClaims; err error }
func (v contractHAVerifier) Verify(string, time.Time) (auth.AccessTokenClaims, error) { return v.claims, v.err }

type contractHAHTTPService struct {
	create homeassistant.IntegrationDTO
	createErr error
	commandCalls int
	lastCommand homeassistant.CommandRequest
}
func (s *contractHAHTTPService) CreateIntegration(context.Context, homeassistant.Actor, homeassistant.AddIntegrationRequest) (homeassistant.IntegrationDTO, error) { return s.create, s.createErr }
func (*contractHAHTTPService) ListIntegrations(context.Context, homeassistant.Actor) ([]homeassistant.IntegrationDTO, error) { return nil, nil }
func (*contractHAHTTPService) UpdateIntegration(context.Context, homeassistant.Actor, string, homeassistant.UpdateIntegrationRequest) (homeassistant.IntegrationDTO, error) { return homeassistant.IntegrationDTO{}, nil }
func (*contractHAHTTPService) DeleteIntegration(context.Context, homeassistant.Actor, string) error { return nil }
func (*contractHAHTTPService) TestIntegration(context.Context, homeassistant.Actor, string) (homeassistant.ConnectionTestDTO, error) { return homeassistant.ConnectionTestDTO{}, nil }
func (*contractHAHTTPService) Discover(context.Context, homeassistant.Actor, string) (homeassistant.DiscoveryDTO, error) { return homeassistant.DiscoveryDTO{}, nil }
func (*contractHAHTTPService) ListEntities(context.Context, homeassistant.Actor, string, bool) ([]homeassistant.EntityDTO, error) { return nil, nil }
func (*contractHAHTTPService) GetState(context.Context, homeassistant.Actor, string, string) (homeassistant.StateDTO, error) { return homeassistant.StateDTO{}, nil }
func (s *contractHAHTTPService) ExecuteCommand(_ context.Context, _ homeassistant.Actor, _ string, _ string, request homeassistant.CommandRequest) (homeassistant.CommandDTO, error) { s.commandCalls++; s.lastCommand = request; return homeassistant.CommandDTO{}, nil }
func (*contractHAHTTPService) ListPermissions(context.Context, homeassistant.Actor) ([]homeassistant.PermissionDTO, error) { return nil, nil }
func (*contractHAHTTPService) UpdatePermission(context.Context, homeassistant.Actor, homeassistant.PermissionRequest) (homeassistant.PermissionDTO, error) { return homeassistant.PermissionDTO{}, nil }

func contractHAClaims() auth.AccessTokenClaims { return auth.AccessTokenClaims{UserID: "user-1", FamilyID: "family-1", Role: string(homeassistant.RoleMember), ExpiresAt: time.Now().Add(time.Hour)} }

func TestHAErrorStatusMappingCoversStableContract(t *testing.T) {
	cases := []struct { code string; want int }{
		{string(homeassistant.CodeUnauthorized), http.StatusUnauthorized},
		{string(homeassistant.CodeForbidden), http.StatusForbidden},
		{string(homeassistant.CodeNotFound), http.StatusNotFound},
		{string(homeassistant.CodeIntegrationUnavailable), http.StatusServiceUnavailable},
		{string(homeassistant.CodeNotConfigured), http.StatusServiceUnavailable},
		{string(homeassistant.CodeAuditFailure), http.StatusInternalServerError},
		{"HA_INVALID_PARAMETERS", http.StatusBadRequest},
		{string(homeassistant.CodeUnsupportedCommand), http.StatusBadRequest},
	}
	for _, test := range cases {
		status := haStatus(test.code)
		if status != test.want { t.Errorf("haStatus(%q) = %d, want %d", test.code, status, test.want) }
	}
}

func TestHAServiceErrorsDoNotExposeUnderlyingHAOrTokenDetails(t *testing.T) {
	secret := "secret-token-123456"
	underlying := errors.New("POST /api/services/light/turn_on token=" + secret)
	code, message, details, status := mapServiceError(&homeassistant.BusinessError{Code: homeassistant.CodeIntegrationUnavailable, Message: "Home Assistant command failed", Cause: underlying})
	if code != string(homeassistant.CodeIntegrationUnavailable) || status != http.StatusServiceUnavailable { t.Fatalf("mapped error = %q/%d", code, status) }
	if strings.Contains(message, secret) || details != nil { t.Fatalf("mapped error exposed sensitive details: message=%q details=%#v", message, details) }
}

func TestHAIntegrationHTTPResponseDoesNotExposeTokenFields(t *testing.T) {
	service := &contractHAHTTPService{create: homeassistant.IntegrationDTO{ID: "integration-1", Name: "HA", BaseURL: "http://ha.local", Status: homeassistant.IntegrationHealthy, Enabled: true}}
	handler := NewRouter(Dependencies{HomeAssistant: service, Verifier: contractHAVerifier{claims: contractHAClaims()}})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/home-assistant/integrations", strings.NewReader(`{"name":"HA","base_url":"http://ha.local","access_token":"secret-token-123456"}`))
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusCreated { t.Fatalf("status = %d, body=%s", resp.Code, resp.Body.String()) }
	body := resp.Body.String()
	for _, forbidden := range []string{"secret-token-123456", "access_token", "key_version", "ciphertext"} {
		if strings.Contains(body, forbidden) { t.Fatalf("HTTP response contains forbidden field %q: %s", forbidden, body) }
	}
}

func TestHACommandHTTPRejectsRawServiceDataAndPreservesTypedRequestID(t *testing.T) {
	service := &contractHAHTTPService{}
	handler := NewRouter(Dependencies{HomeAssistant: service, Verifier: contractHAVerifier{claims: contractHAClaims()}})
	bad := httptest.NewRequest(http.MethodPost, "/api/v1/home-assistant/entities/light.kitchen/commands?integration_id=integration-1", strings.NewReader(`{"command":"turn_on","request_id":"123e4567-e89b-12d3-a456-426614174000","service_data":{"brightness":100}}`))
	bad.Header.Set("Authorization", "Bearer token")
	bad.Header.Set("Content-Type", "application/json")
	badResponse := httptest.NewRecorder()
	handler.ServeHTTP(badResponse, bad)
	if badResponse.Code != http.StatusBadRequest { t.Fatalf("raw service_data status = %d, body=%s", badResponse.Code, badResponse.Body.String()) }
	if service.commandCalls != 0 { t.Fatalf("service called for rejected raw command: %d", service.commandCalls) }

	good := httptest.NewRequest(http.MethodPost, "/api/v1/home-assistant/entities/light.kitchen/commands?integration_id=integration-1", strings.NewReader(`{"command":"turn_on","parameters":{},"request_id":"123e4567-e89b-12d3-a456-426614174000"}`))
	good.Header.Set("Authorization", "Bearer token")
	good.Header.Set("Content-Type", "application/json")
	goodResponse := httptest.NewRecorder()
	handler.ServeHTTP(goodResponse, good)
	if goodResponse.Code != http.StatusOK { t.Fatalf("typed command status = %d, body=%s", goodResponse.Code, goodResponse.Body.String()) }
	if service.commandCalls != 1 || service.lastCommand.RequestID != "123e4567-e89b-12d3-a456-426614174000" || service.lastCommand.Command != homeassistant.CommandTurnOn { t.Fatalf("forwarded request = %#v, calls=%d", service.lastCommand, service.commandCalls) }
}

func TestHACommandHTTPRejectsUnknownJSONEvenWhenRequestIDIsPresent(t *testing.T) {
	service := &contractHAHTTPService{}
	handler := NewRouter(Dependencies{HomeAssistant: service, Verifier: contractHAVerifier{claims: contractHAClaims()}})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/home-assistant/entities/light.kitchen/commands?integration_id=integration-1", strings.NewReader(`{"command":"turn_on","parameters":{"domain":"light"},"request_id":"123e4567-e89b-12d3-a456-426614174000"}`))
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest { t.Fatalf("unknown typed parameter status = %d, body=%s", resp.Code, resp.Body.String()) }
	var payload map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil { t.Fatalf("error response is not JSON: %v", err) }
}
