package platform

import (
	"encoding/json"
	"net/http"
)

type APIError struct {
	Code      string         `json:"code"`
	Message   string         `json:"message"`
	Details   map[string]any `json:"details,omitempty"`
	RequestID string         `json:"request_id"`
}

type ErrorEnvelope struct {
	Error APIError `json:"error"`
}

func WriteJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func WriteAPIError(w http.ResponseWriter, r *http.Request, status int, code, message string, details map[string]any) {
	WriteJSON(w, status, ErrorEnvelope{Error: APIError{
		Code: code, Message: message, Details: details, RequestID: RequestIDFromContext(r.Context()),
	}})
}

func NotImplementedHandler(w http.ResponseWriter, r *http.Request) {
	WriteAPIError(w, r, http.StatusNotImplemented, "NOT_IMPLEMENTED", "this endpoint is not implemented in the platform skeleton", nil)
}
