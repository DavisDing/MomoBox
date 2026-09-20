package httpapi

import (
	"errors"
	"net/http"
	"strings"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/family"
	homeassistant "github.com/momobox/backend/internal/homeassistant"
	syncservice "github.com/momobox/backend/internal/sync"
	"github.com/momobox/backend/internal/syncdevice"
)

func (h *Handler) serviceError(w http.ResponseWriter, r *http.Request, err error) {
	if err == nil {
		return
	}
	code, message, details, status := mapServiceError(err)
	writeError(w, r, status, code, message, details)
}

func mapServiceError(err error) (string, string, map[string]any, int) {
	var authErr *auth.ServiceError
	if errors.As(err, &authErr) {
		return string(authErr.Code), safeMessage(authErr.Message), nil, authStatus(string(authErr.Code))
	}
	var familyErr *family.ServiceError
	if errors.As(err, &familyErr) {
		return string(familyErr.Code), safeMessage(familyErr.Message), nil, familyStatus(string(familyErr.Code))
	}
	var haErr *homeassistant.BusinessError
	if errors.As(err, &haErr) {
		return string(haErr.Code), safeMessage(haErr.Message), nil, haStatus(string(haErr.Code))
	}
	var syncErr *syncservice.BusinessError
	if errors.As(err, &syncErr) {
		return syncErr.Code, safeMessage(syncErr.Message), syncErr.Details, syncStatus(syncErr.Code)
	}
	if errors.Is(err, syncservice.ErrInvalidRequest) || errors.Is(err, syncdevice.ErrValidation) {
		return "VALIDATION_FAILED", "request is invalid", nil, http.StatusBadRequest
	}
	if errors.Is(err, syncservice.ErrDeviceNotFound) || errors.Is(err, syncdevice.ErrNotFound) || errors.Is(err, syncdevice.ErrCurrentUnavailable) {
		return "NOT_FOUND", "resource was not found", nil, http.StatusNotFound
	}
	if errors.Is(err, syncdevice.ErrUnauthorized) {
		return "UNAUTHORIZED", "request is not authorized", nil, http.StatusUnauthorized
	}
	if errors.Is(err, syncdevice.ErrForbidden) {
		return "FORBIDDEN", "request is forbidden", nil, http.StatusForbidden
	}
	if errors.Is(err, syncdevice.ErrConflict) || errors.Is(err, syncdevice.ErrCursorRegression) {
		return "CONFLICT", "request conflicts with current state", nil, http.StatusConflict
	}
	if errors.Is(err, syncdevice.ErrRevoked) {
		return "FORBIDDEN", "device is revoked", nil, http.StatusForbidden
	}
	if errors.Is(err, syncservice.ErrNotFound) {
		return "NOT_FOUND", "resource was not found", nil, http.StatusNotFound
	}
	return "INTERNAL_ERROR", "internal server error", nil, http.StatusInternalServerError
}

func safeMessage(message string) string {
	message = strings.TrimSpace(message)
	if message == "" {
		return "request could not be processed"
	}
	return message
}

func authStatus(code string) int {
	switch code {
	case "VALIDATION_FAILED":
		return http.StatusBadRequest
	case "AUTH_INVALID_CREDENTIALS", "AUTH_REFRESH_REVOKED", "AUTH_TOKEN_EXPIRED", "AUTH_INVALID_TOKEN", "AUTH_USER_NOT_FOUND":
		return http.StatusUnauthorized
	case "AUTH_EMAIL_EXISTS", "AUTH_REGISTRATION_CLOSED", "CONFLICT":
		return http.StatusConflict
	default:
		return http.StatusInternalServerError
	}
}

func familyStatus(code string) int {
	switch code {
	case "VALIDATION_FAILED":
		return http.StatusBadRequest
	case "UNAUTHORIZED":
		return http.StatusUnauthorized
	case "FORBIDDEN":
		return http.StatusForbidden
	case "NOT_FOUND", "FAMILY_INVITE_INVALID", "FAMILY_INVITE_EXPIRED", "FAMILY_INVITE_EXHAUSTED":
		return http.StatusNotFound
	case "CONFLICT", "FAMILY_ALREADY_MEMBER":
		return http.StatusConflict
	default:
		return http.StatusInternalServerError
	}
}

func haStatus(code string) int {
	switch code {
	case "HA_INVALID_ARGUMENT", "HA_INVALID_URL", "HA_INVALID_COMMAND", "HA_INVALID_PARAMETERS", "HA_INVALID_ROLE":
		return http.StatusBadRequest
	case "HA_UNAUTHORIZED":
		return http.StatusUnauthorized
	case "HA_FORBIDDEN":
		return http.StatusForbidden
	case "HA_NOT_FOUND":
		return http.StatusNotFound
	case "HA_UNAVAILABLE", "HOME_ASSISTANT_NOT_CONFIGURED":
		return http.StatusServiceUnavailable
	case "HA_AUDIT_FAILURE":
		return http.StatusInternalServerError
	default:
		return http.StatusInternalServerError
	}
}

func syncStatus(code string) int {
	switch code {
	case "VALIDATION_FAILED", "INVALID_REQUEST":
		return http.StatusBadRequest
	case "UNAUTHORIZED":
		return http.StatusUnauthorized
	case "FORBIDDEN":
		return http.StatusForbidden
	case "NOT_FOUND":
		return http.StatusNotFound
	case "CONFLICT", "VERSION_CONFLICT", "IDEMPOTENCY_CONFLICT":
		return http.StatusConflict
	default:
		return http.StatusInternalServerError
	}
}
