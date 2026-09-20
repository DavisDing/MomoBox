package syncdevice

import "errors"

var (
	ErrUnauthorized       = errors.New("syncdevice: unauthorized")
	ErrForbidden          = errors.New("syncdevice: forbidden")
	ErrNotFound           = errors.New("syncdevice: not found")
	ErrConflict           = errors.New("syncdevice: conflict")
	ErrValidation         = errors.New("syncdevice: validation failed")
	ErrRevoked            = errors.New("syncdevice: device revoked")
	ErrCursorRegression   = errors.New("syncdevice: sync cursor regression")
	ErrCurrentUnavailable = errors.New("syncdevice: current device unavailable")
)

// ValidationError identifies the request field that failed validation. It wraps
// ErrValidation so callers can map it to the API's validation error response.
type ValidationError struct {
	Field  string
	Reason string
}

func (e *ValidationError) Error() string {
	if e.Field == "" {
		return "syncdevice: validation failed"
	}
	if e.Reason == "" {
		return "syncdevice: invalid " + e.Field
	}
	return "syncdevice: invalid " + e.Field + ": " + e.Reason
}

func (e *ValidationError) Unwrap() error { return ErrValidation }
