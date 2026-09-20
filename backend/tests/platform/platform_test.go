package platform_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/platform"
)

type fakeDB struct{ err error }

func (f fakeDB) PingContext(context.Context) error { return f.err }
func (f fakeDB) Close() error                      { return nil }

func testConfig() platform.Config {
	return platform.Config{
		HTTPAddr: "127.0.0.1:8080", JWTSecret: strings.Repeat("j", 32), RefreshTokenPepper: strings.Repeat("p", 32), HATokenEncryptionKey: strings.Repeat("h", 32),
		RegistrationMode: "first_setup", AccessTokenTTL: 15 * time.Minute, RefreshTokenTTL: 24 * time.Hour,
		MaxRequestBodyBytes: 1024, AppVersion: "test", APIVersion: "v1", SchemaVersion: 1, SyncProtocolVersion: 1,
	}
}

func TestConfigValidate(t *testing.T) {
	cfg := testConfig()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	cfg.RegistrationMode = "bad"
	if err := cfg.Validate(); err == nil {
		t.Fatal("invalid registration mode accepted")
	}
}

func TestRequestIDMiddlewareUsesAndGeneratesIDs(t *testing.T) {
	handler := platform.RequestIDMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := platform.RequestIDFromContext(r.Context()); got == "" {
			t.Fatal("request ID missing from context")
		}
		platform.WriteAPIError(w, r, http.StatusBadRequest, "TEST", "bad request", nil)
	}))

	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("X-Request-ID", "11111111-1111-4111-8111-111111111111")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Header().Get("X-Request-ID") != "11111111-1111-4111-8111-111111111111" {
		t.Fatal("client request ID was not preserved")
	}
	var envelope platform.ErrorEnvelope
	if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.Error.RequestID != "11111111-1111-4111-8111-111111111111" {
		t.Fatalf("unexpected request ID: %q", envelope.Error.RequestID)
	}

	request = httptest.NewRequest(http.MethodGet, "/", nil)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Header().Get("X-Request-ID") == "" {
		t.Fatal("generated request ID missing")
	}
}

func TestHealthHandler(t *testing.T) {
	server := platform.NewHTTPServer(testConfig(), fakeDB{})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	response := httptest.NewRecorder()
	server.HTTPServer.Handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", response.Code)
	}

	server = platform.NewHTTPServer(testConfig(), fakeDB{err: errors.New("offline")})
	response = httptest.NewRecorder()
	server.HTTPServer.Handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", response.Code)
	}
}

func TestPasswordAndTokenHelpers(t *testing.T) {
	password := "correct horse battery staple"
	hash, err := platform.HashPassword(password)
	if err != nil {
		t.Fatal(err)
	}
	if err := platform.ComparePassword(hash, password); err != nil {
		t.Fatal(err)
	}
	if err := platform.ComparePassword(hash, "wrong password"); err == nil {
		t.Fatal("wrong password accepted")
	}

	now := time.Unix(1_700_000_000, 0)
	claims := platform.AccessTokenClaims{UserID: "user-1", FamilyID: "family-1", Role: "owner", ExpiresAt: now.Add(time.Hour).Unix()}
	secret := strings.Repeat("s", 32)
	token, err := platform.SignAccessToken(claims, secret, now)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := platform.ParseAccessToken(token, secret, now)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.UserID != claims.UserID || parsed.FamilyID != claims.FamilyID {
		t.Fatalf("claims changed: %#v", parsed)
	}
	if _, err := platform.ParseAccessToken(token, strings.Repeat("x", 32), now); err == nil {
		t.Fatal("token verified with wrong secret")
	}

	refresh, err := platform.NewRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(refresh) < 32 || platform.HashRefreshToken(refresh, "pepper") == "" {
		t.Fatal("refresh token helper failed")
	}
}

func TestMigrationPlaceholderDoesNotPretendToRun(t *testing.T) {
	if err := (platform.PlaceholderMigrationRunner{}).Run(context.Background()); !errors.Is(err, platform.ErrMigrationsNotImplemented) {
		t.Fatalf("error = %v, want ErrMigrationsNotImplemented", err)
	}
}
