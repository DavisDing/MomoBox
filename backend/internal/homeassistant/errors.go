package homeassistant

import "fmt"

// ErrorCode is a stable business error code. HTTP adapters may map these codes
// to the API contract without exposing implementation details or secrets.
type ErrorCode string

const (
	CodeInvalidArgument        ErrorCode = "HA_INVALID_ARGUMENT"
	CodeInvalidURL             ErrorCode = "HA_INVALID_URL"
	CodeInvalidToken           ErrorCode = "HA_INVALID_TOKEN"
	CodeNotConfigured          ErrorCode = "HOME_ASSISTANT_NOT_CONFIGURED"
	CodeUnauthorized           ErrorCode = "HA_UNAUTHORIZED"
	CodeForbidden              ErrorCode = "HA_FORBIDDEN"
	CodeNotFound               ErrorCode = "HA_NOT_FOUND"
	CodeInvalidCommand         ErrorCode = "HA_INVALID_COMMAND"
	CodeInvalidParameters      ErrorCode = "HA_INVALID_PARAMETERS"
	CodeUnsupportedCommand     ErrorCode = "HA_UNSUPPORTED_COMMAND"
	CodeIntegrationUnavailable ErrorCode = "HA_UNAVAILABLE"
	CodeInvalidRole            ErrorCode = "HA_INVALID_ROLE"
	CodeAuditFailure           ErrorCode = "HA_AUDIT_FAILURE"
)

// BusinessError is safe to return from an adapter. Cause is deliberately kept
// separate from Message so connectors cannot accidentally expose token, SQL,
// or HTTP details to clients.
type BusinessError struct {
	Code    ErrorCode
	Message string
	Cause   error
}

func (e *BusinessError) Error() string {
	if e == nil {
		return ""
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func (e *BusinessError) Unwrap() error { return e.Cause }

func businessError(code ErrorCode, message string, cause error) error {
	return &BusinessError{Code: code, Message: message, Cause: cause}
}
