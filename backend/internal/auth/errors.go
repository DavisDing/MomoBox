package auth

import "errors"

// ErrorCode is stable for HTTP adapters and clients. The service layer never
// exposes database or cryptographic implementation details.
type ErrorCode string

const (
	CodeValidation         ErrorCode = "VALIDATION_FAILED"
	CodeRegistrationClosed ErrorCode = "AUTH_REGISTRATION_CLOSED"
	CodeEmailAlreadyExists ErrorCode = "AUTH_EMAIL_EXISTS"
	CodeInvalidCredentials ErrorCode = "AUTH_INVALID_CREDENTIALS"
	CodeRefreshRevoked     ErrorCode = "AUTH_REFRESH_REVOKED"
	CodeTokenExpired       ErrorCode = "AUTH_TOKEN_EXPIRED"
	CodeInvalidToken       ErrorCode = "AUTH_INVALID_TOKEN"
	CodeUserNotFound       ErrorCode = "AUTH_USER_NOT_FOUND"
	CodeConflict           ErrorCode = "CONFLICT"
)

// ServiceError is safe for an HTTP adapter to map to a response. Cause is
// intentionally not serialized and should only be used for internal logging.
type ServiceError struct {
	Code    ErrorCode
	Message string
	Cause   error
}

func (e *ServiceError) Error() string { return string(e.Code) + ": " + e.Message }
func (e *ServiceError) Unwrap() error { return e.Cause }

func newError(code ErrorCode, message string) error {
	return &ServiceError{Code: code, Message: message}
}

func withCause(code ErrorCode, message string, cause error) error {
	return &ServiceError{Code: code, Message: message, Cause: cause}
}

func hasCode(err error, code ErrorCode) bool {
	var serviceErr *ServiceError
	return errors.As(err, &serviceErr) && serviceErr.Code == code
}
