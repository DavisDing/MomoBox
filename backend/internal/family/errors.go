package family

import "errors"

type ErrorCode string

const (
	CodeValidation      ErrorCode = "VALIDATION_FAILED"
	CodeUnauthorized    ErrorCode = "UNAUTHORIZED"
	CodeForbidden       ErrorCode = "FORBIDDEN"
	CodeNotFound        ErrorCode = "NOT_FOUND"
	CodeConflict        ErrorCode = "CONFLICT"
	CodeInviteInvalid   ErrorCode = "FAMILY_INVITE_INVALID"
	CodeInviteExpired   ErrorCode = "FAMILY_INVITE_EXPIRED"
	CodeInviteExhausted ErrorCode = "FAMILY_INVITE_EXHAUSTED"
	CodeAlreadyMember   ErrorCode = "FAMILY_ALREADY_MEMBER"
)

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
