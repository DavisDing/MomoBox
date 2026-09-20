package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
)

type testVerifier struct {
	claims auth.AccessTokenClaims
	err    error
}

func (v testVerifier) Verify(string, time.Time) (auth.AccessTokenClaims, error) {
	return v.claims, v.err
}

func TestRouterRejectsMissingServiceWithoutClaimingSuccess(t *testing.T) {
	handler := NewRouter(Dependencies{Verifier: testVerifier{claims: auth.AccessTokenClaims{
		UserID: "user-1", ExpiresAt: time.Now().Add(time.Hour),
	}}})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"a@example.com","password":"long-enough-password"}`))
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d; body=%s", resp.Code, http.StatusInternalServerError, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "HTTPAPI_CONFIGURATION_ERROR") {
		t.Fatalf("body does not identify configuration error: %s", resp.Body.String())
	}
}

func TestProtectedRouteRequiresBearerToken(t *testing.T) {
	handler := NewRouter(Dependencies{Auth: fakeAuthService{}})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d; body=%s", resp.Code, http.StatusUnauthorized, resp.Body.String())
	}
}

type fakeAuthService struct{}

func (fakeAuthService) Register(context.Context, auth.RegisterRequest) (auth.AuthResponse, error) {
	return auth.AuthResponse{}, nil
}
func (fakeAuthService) Login(context.Context, auth.LoginRequest) (auth.AuthResponse, error) {
	return auth.AuthResponse{}, nil
}
func (fakeAuthService) Refresh(context.Context, auth.RefreshRequest) (auth.AuthResponse, error) {
	return auth.AuthResponse{}, nil
}
func (fakeAuthService) Logout(context.Context, auth.RefreshRequest) error { return nil }
func (fakeAuthService) CurrentUser(context.Context, string) (auth.MeResponse, error) {
	return auth.MeResponse{}, nil
}
