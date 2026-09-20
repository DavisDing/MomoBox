package sync

import (
	"errors"
	"fmt"
)

var (
	ErrInvalidRequest = errors.New("invalid sync request")
	ErrDeviceNotFound = errors.New("sync device not found")
	ErrNotFound       = errors.New("sync resource not found")
)

// BusinessError is a domain error that can be returned as a per-change
// rejection without failing the whole push request.
type BusinessError struct {
	Code    string
	Message string
	Details map[string]any
}

func (e *BusinessError) Error() string {
	if e == nil {
		return ""
	}
	if e.Code == "" {
		return e.Message
	}
	if e.Message == "" {
		return e.Code
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func NewBusinessError(code, message string, details map[string]any) *BusinessError {
	return &BusinessError{Code: code, Message: message, Details: details}
}

func businessCode(err error) (code, message string, details map[string]any, ok bool) {
	var domainErr *BusinessError
	if errors.As(err, &domainErr) {
		return domainErr.Code, domainErr.Message, cloneMap(domainErr.Details), true
	}
	if errors.Is(err, ErrNotFound) {
		return "NOT_FOUND", "资源不存在", nil, true
	}
	return "", "", nil, false
}
