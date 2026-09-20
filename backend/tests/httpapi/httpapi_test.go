package httpapi_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/family"
	"github.com/momobox/backend/internal/homeassistant"
	"github.com/momobox/backend/internal/httpapi"
)

type verifier struct {
	claims auth.AccessTokenClaims
	err    error
}

func (v verifier) Verify(string, time.Time) (auth.AccessTokenClaims, error) { return v.claims, v.err }

type authFake struct {
	loginCalled bool
	request     auth.LoginRequest
}

func (f *authFake) Register(context.Context, auth.RegisterRequest) (auth.AuthResponse, error) {
	return auth.AuthResponse{}, nil
}
func (f *authFake) Login(_ context.Context, request auth.LoginRequest) (auth.AuthResponse, error) {
	f.loginCalled = true
	f.request = request
	return auth.AuthResponse{User: auth.User{ID: "user-1", Email: request.Email, Nickname: "Momo"}, AccessToken: "access", RefreshToken: strings.Repeat("r", 32), ExpiresIn: 900}, nil
}
func (f *authFake) Refresh(context.Context, auth.RefreshRequest) (auth.AuthResponse, error) {
	return auth.AuthResponse{}, nil
}
func (f *authFake) Logout(context.Context, auth.RefreshRequest) error { return nil }
func (f *authFake) CurrentUser(context.Context, string) (auth.MeResponse, error) {
	return auth.MeResponse{}, nil
}

func validClaims() auth.AccessTokenClaims {
	return auth.AccessTokenClaims{UserID: "user-1", FamilyID: "family-1", Role: "owner", DeviceID: "device-1", ExpiresAt: time.Now().Add(time.Hour)}
}

func TestMissingServiceReturnsConfigurationErrorAndRequestID(t *testing.T) {
	handler := httpapi.NewRouter(httpapi.Dependencies{Verifier: verifier{claims: validClaims()}})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"a@example.com","password":"password"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Request-ID", "00000000-0000-4000-8000-000000000001")
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)

	if res.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", res.Code)
	}
	var body struct {
		Error struct {
			Code      string `json:"code"`
			RequestID string `json:"request_id"`
		} `json:"error"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Error.Code != "HTTPAPI_CONFIGURATION_ERROR" {
		t.Fatalf("code = %q", body.Error.Code)
	}
	if body.Error.RequestID != "00000000-0000-4000-8000-000000000001" {
		t.Fatalf("request id = %q", body.Error.RequestID)
	}
}

func TestLoginDispatchesToInjectedService(t *testing.T) {
	service := &authFake{}
	handler := httpapi.NewRouter(httpapi.Dependencies{Auth: service})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"a@example.com","password":"secret"}`))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)

	if res.Code != http.StatusOK || !service.loginCalled {
		t.Fatalf("status = %d, called = %v", res.Code, service.loginCalled)
	}
	if service.request.Email != "a@example.com" {
		t.Fatalf("email = %q", service.request.Email)
	}
}

func TestProtectedRouteRejectsMissingBearer(t *testing.T) {
	handler := httpapi.NewRouter(httpapi.Dependencies{Auth: &authFake{}, Verifier: verifier{claims: validClaims()}})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)
	if res.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", res.Code)
	}
}

func TestJSONRejectsUnknownFieldsAndOversizedBody(t *testing.T) {
	handler := httpapi.NewRouter(httpapi.Dependencies{Auth: &authFake{}, Config: httpapi.Config{MaxRequestBodyBytes: 32}})
	for _, body := range []string{`{"email":"a@example.com","password":"p","extra":true}`, `{"email":"a@example.com","password":"` + strings.Repeat("x", 100) + `"}`} {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, req)
		if res.Code != http.StatusBadRequest {
			t.Fatalf("body status = %d, want 400", res.Code)
		}
	}
}

func TestMethodMismatchReturns405(t *testing.T) {
	handler := httpapi.NewRouter(httpapi.Dependencies{Auth: &authFake{}})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/auth/login", nil)
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)
	if res.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", res.Code)
	}
	if res.Header().Get("Allow") != http.MethodPost {
		t.Fatalf("allow = %q", res.Header().Get("Allow"))
	}
}

type familyFake struct {
	userID   string
	familyID string
}

func (f *familyFake) CreateFamily(context.Context, string, family.CreateFamilyRequest) (family.FamilyResponse, error) {
	return family.FamilyResponse{}, nil
}
func (f *familyFake) CurrentFamily(context.Context, string) (family.FamilyResponse, error) {
	return family.FamilyResponse{}, nil
}
func (f *familyFake) CreateInvite(context.Context, string, string, family.CreateInviteRequest) (family.InviteResponse, error) {
	return family.InviteResponse{}, nil
}
func (f *familyFake) Join(context.Context, string, family.JoinFamilyRequest) (family.FamilyResponse, error) {
	return family.FamilyResponse{}, nil
}
func (f *familyFake) ListMembers(_ context.Context, userID, familyID string) (family.MembersResponse, error) {
	f.userID, f.familyID = userID, familyID
	return family.MembersResponse{Members: []family.FamilyMember{}}, nil
}

func TestFamilyRouteUsesVerifiedClaims(t *testing.T) {
	service := &familyFake{}
	handler := httpapi.NewRouter(httpapi.Dependencies{Family: service, Verifier: verifier{claims: validClaims()}})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/families/members", nil)
	req.Header.Set("Authorization", "Bearer signed-token")
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.Code)
	}
	if service.userID != "user-1" || service.familyID != "family-1" {
		t.Fatalf("claims not forwarded: user=%q family=%q", service.userID, service.familyID)
	}
}

type homeAssistantFake struct {
	httpapi.HomeAssistantService
	stateCalls        int
	commandCalls      int
	permissionCalls   int
	integrationID     string
	entityID          string
	permissionRequest homeassistant.PermissionRequest
}

func (f *homeAssistantFake) GetState(_ context.Context, _ homeassistant.Actor, integrationID, entityID string) (homeassistant.StateDTO, error) {
	f.stateCalls++
	f.integrationID = integrationID
	f.entityID = entityID
	return homeassistant.StateDTO{EntityID: entityID, State: "on", FetchedAt: time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC)}, nil
}

func (f *homeAssistantFake) ExecuteCommand(_ context.Context, _ homeassistant.Actor, integrationID, entityID string, request homeassistant.CommandRequest) (homeassistant.CommandDTO, error) {
	f.commandCalls++
	f.integrationID = integrationID
	f.entityID = entityID
	return homeassistant.CommandDTO{Accepted: true, EntityID: entityID, Command: request.Command, ExecutedAt: time.Date(2026, 9, 20, 12, 0, 1, 0, time.UTC)}, nil
}

func (f *homeAssistantFake) UpdatePermission(_ context.Context, _ homeassistant.Actor, request homeassistant.PermissionRequest) (homeassistant.PermissionDTO, error) {
	f.permissionCalls++
	f.permissionRequest = request
	return homeassistant.PermissionDTO{IntegrationID: request.IntegrationID, EntityID: request.EntityID, Role: request.Role, CanView: request.CanView, CanControl: request.CanControl, AllowedCommands: request.AllowedCommands}, nil
}

func TestHomeAssistantStateRequiresAndForwardsIntegrationID(t *testing.T) {
	service := &homeAssistantFake{}
	handler := httpapi.NewRouter(httpapi.Dependencies{HomeAssistant: service, Verifier: verifier{claims: validClaims()}})

	missing := httptest.NewRequest(http.MethodGet, "/api/v1/home-assistant/entities/light.kitchen/state", nil)
	missing.Header.Set("Authorization", "Bearer signed-token")
	missingResponse := httptest.NewRecorder()
	handler.ServeHTTP(missingResponse, missing)
	if missingResponse.Code != http.StatusBadRequest || service.stateCalls != 0 {
		t.Fatalf("missing integration_id status/calls = %d/%d", missingResponse.Code, service.stateCalls)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/home-assistant/entities/light.kitchen/state?integration_id=integration-2", nil)
	req.Header.Set("Authorization", "Bearer signed-token")
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
	}
	if service.stateCalls != 1 || service.integrationID != "integration-2" || service.entityID != "light.kitchen" {
		t.Fatalf("forwarded state key = calls:%d integration:%q entity:%q", service.stateCalls, service.integrationID, service.entityID)
	}
}

func TestHomeAssistantCommandRequiresAndForwardsIntegrationID(t *testing.T) {
	service := &homeAssistantFake{}
	handler := httpapi.NewRouter(httpapi.Dependencies{HomeAssistant: service, Verifier: verifier{claims: validClaims()}})
	body := `{"command":"turn_on","parameters":{},"request_id":"123e4567-e89b-12d3-a456-426614174000"}`

	missing := httptest.NewRequest(http.MethodPost, "/api/v1/home-assistant/entities/light.kitchen/commands", strings.NewReader(body))
	missing.Header.Set("Authorization", "Bearer signed-token")
	missing.Header.Set("Content-Type", "application/json")
	missingResponse := httptest.NewRecorder()
	handler.ServeHTTP(missingResponse, missing)
	if missingResponse.Code != http.StatusBadRequest || service.commandCalls != 0 {
		t.Fatalf("missing integration_id status/calls = %d/%d", missingResponse.Code, service.commandCalls)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/home-assistant/entities/light.kitchen/commands?integration_id=integration-2", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer signed-token")
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
	}
	if service.commandCalls != 1 || service.integrationID != "integration-2" || service.entityID != "light.kitchen" {
		t.Fatalf("forwarded command key = calls:%d integration:%q entity:%q", service.commandCalls, service.integrationID, service.entityID)
	}
}

func TestHomeAssistantPermissionRequestAndResponseIncludeIntegrationID(t *testing.T) {
	service := &homeAssistantFake{}
	handler := httpapi.NewRouter(httpapi.Dependencies{HomeAssistant: service, Verifier: verifier{claims: validClaims()}})
	body := `{"integration_id":"integration-2","entity_id":"light.kitchen","role":"member","can_view":true,"can_control":true,"allowed_commands":["turn_on"]}`
	req := httptest.NewRequest(http.MethodPut, "/api/v1/home-assistant/permissions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer signed-token")
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
	}
	if service.permissionCalls != 1 || service.permissionRequest.IntegrationID != "integration-2" {
		t.Fatalf("permission request = %#v", service.permissionRequest)
	}
	var response struct {
		IntegrationID string `json:"integration_id"`
		EntityID      string `json:"entity_id"`
	}
	if err := json.NewDecoder(res.Body).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.IntegrationID != "integration-2" || response.EntityID != "light.kitchen" {
		t.Fatalf("permission response = %#v", response)
	}
}
