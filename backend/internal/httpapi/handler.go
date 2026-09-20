package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/momobox/backend/internal/auth"
	homeassistant "github.com/momobox/backend/internal/homeassistant"
	"github.com/momobox/backend/internal/platform"
	"github.com/momobox/backend/internal/syncdevice"
)

type Handler struct {
	deps Dependencies
	cfg  Config
}

func NewHandler(deps Dependencies) *Handler {
	cfg := deps.Config
	if cfg.MaxRequestBodyBytes <= 0 {
		cfg.MaxRequestBodyBytes = defaultMaxRequestBodyBytes
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	return &Handler{deps: deps, cfg: cfg}
}

func NewRouter(deps Dependencies) http.Handler { return NewHandler(deps).Routes() }

func (h *Handler) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/auth/register", h.register)
	mux.HandleFunc("/api/v1/auth/login", h.login)
	mux.HandleFunc("/api/v1/auth/refresh", h.refresh)
	mux.HandleFunc("/api/v1/auth/logout", h.logout)
	mux.HandleFunc("/api/v1/me", h.me)
	mux.HandleFunc("/api/v1/families", h.createFamily)
	mux.HandleFunc("/api/v1/families/current", h.currentFamily)
	mux.HandleFunc("/api/v1/families/invites", h.createInvite)
	mux.HandleFunc("/api/v1/families/join", h.joinFamily)
	mux.HandleFunc("/api/v1/families/members", h.listMembers)
	mux.HandleFunc("/api/v1/devices", h.devicesRoute)
	mux.HandleFunc("/api/v1/devices/{device_id}", h.revokeDevice)
	mux.HandleFunc("/api/v1/sync/bootstrap", h.bootstrap)
	mux.HandleFunc("/api/v1/sync/bootstrap/confirm", h.confirmBootstrap)
	mux.HandleFunc("/api/v1/sync/push", h.push)
	mux.HandleFunc("/api/v1/sync/pull", h.pull)
	mux.HandleFunc("/api/v1/home-assistant/integrations", h.integrationsRoute)
	mux.HandleFunc("/api/v1/home-assistant/integrations/{integration_id}", h.integrationRoute)
	mux.HandleFunc("/api/v1/home-assistant/integrations/{integration_id}/test", h.testIntegration)
	mux.HandleFunc("/api/v1/home-assistant/integrations/{integration_id}/discover", h.discover)
	mux.HandleFunc("/api/v1/home-assistant/entities", h.listEntities)
	mux.HandleFunc("/api/v1/home-assistant/entities/{entity_id}/state", h.getState)
	mux.HandleFunc("/api/v1/home-assistant/entities/{entity_id}/commands", h.executeCommand)
	mux.HandleFunc("/api/v1/home-assistant/permissions", h.permissionsRoute)
	mux.Handle("/api/v1/", http.HandlerFunc(h.notFound))
	return platform.RequestIDMiddleware(h.withBodyLimit(mux))
}

func (h *Handler) withBodyLimit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && (r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodPatch) {
			r.Body = http.MaxBytesReader(w, r.Body, h.cfg.MaxRequestBodyBytes)
		}
		next.ServeHTTP(w, r)
	})
}

func (h *Handler) notFound(w http.ResponseWriter, r *http.Request) {
	writeError(w, r, http.StatusNotFound, "NOT_FOUND", "route not found", nil)
}

func (h *Handler) requireService(w http.ResponseWriter, r *http.Request, name string, service any) bool {
	if service != nil {
		return true
	}
	writeError(w, r, http.StatusInternalServerError, "HTTPAPI_CONFIGURATION_ERROR", "required service is not configured", map[string]any{"service": name})
	return false
}

func (h *Handler) requireAuth(w http.ResponseWriter, r *http.Request) (auth.AccessTokenClaims, string, bool) {
	header := strings.TrimSpace(r.Header.Get("Authorization"))
	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || parts[1] == "" {
		writeError(w, r, http.StatusUnauthorized, "UNAUTHORIZED", "a bearer access token is required", nil)
		return auth.AccessTokenClaims{}, "", false
	}
	if h.deps.Verifier == nil {
		writeError(w, r, http.StatusInternalServerError, "HTTPAPI_CONFIGURATION_ERROR", "claims verifier is not configured", map[string]any{"service": "claims_verifier"})
		return auth.AccessTokenClaims{}, "", false
	}
	token := parts[1]
	now := h.cfg.Now()
	claims, err := h.deps.Verifier.Verify(token, now)
	if err != nil || claims.UserID == "" || !claims.ExpiresAt.After(now) {
		writeError(w, r, http.StatusUnauthorized, "AUTH_INVALID_TOKEN", "access token is invalid", nil)
		return auth.AccessTokenClaims{}, "", false
	}
	return claims, token, true
}

func (h *Handler) decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	contentType := strings.TrimSpace(strings.ToLower(r.Header.Get("Content-Type")))
	if !strings.HasPrefix(contentType, "application/json") {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "content type must be application/json", nil)
		return false
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		message := "request body is invalid JSON"
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			message = "request body is too large"
		}
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", message, nil)
		return false
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "request body must contain exactly one JSON value", nil)
		return false
	}
	return true
}

func (h *Handler) method(w http.ResponseWriter, r *http.Request, want string) bool {
	if r.Method == want {
		return true
	}
	w.Header().Set("Allow", want)
	writeError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", nil)
	return false
}

func bearerToken(r *http.Request) string {
	parts := strings.Fields(strings.TrimSpace(r.Header.Get("Authorization")))
	if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
		return parts[1]
	}
	return ""
}

func (h *Handler) actor(claims auth.AccessTokenClaims) (syncdevice.Actor, homeassistant.Actor) {
	return syncdevice.Actor{UserID: claims.UserID, FamilyID: claims.FamilyID, Role: syncdevice.Role(claims.Role), DeviceID: claims.DeviceID}, homeassistant.Actor{UserID: claims.UserID, FamilyID: claims.FamilyID, Role: homeassistant.Role(claims.Role)}
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	platform.WriteJSON(w, status, payload)
}

func writeNoContent(w http.ResponseWriter) { w.WriteHeader(http.StatusNoContent) }

func writeError(w http.ResponseWriter, r *http.Request, status int, code, message string, details map[string]any) {
	platform.WriteAPIError(w, r, status, code, message, details)
}

func (h *Handler) now() time.Time { return h.cfg.Now() }

func currentDeviceID(w http.ResponseWriter, r *http.Request, claims auth.AccessTokenClaims, requested string) (string, bool) {
	if strings.TrimSpace(claims.DeviceID) == "" {
		writeError(w, r, http.StatusUnauthorized, "AUTH_INVALID_TOKEN", "access token does not identify a device", nil)
		return "", false
	}
	if requested != "" && requested != claims.DeviceID {
		writeError(w, r, http.StatusForbidden, "FORBIDDEN", "device does not match the access token", nil)
		return "", false
	}
	return claims.DeviceID, true
}

func parseInt64Query(r *http.Request, key string) (int64, error) {
	value := strings.TrimSpace(r.URL.Query().Get(key))
	if value == "" {
		return 0, fmt.Errorf("%s is required", key)
	}
	return strconv.ParseInt(value, 10, 64)
}
