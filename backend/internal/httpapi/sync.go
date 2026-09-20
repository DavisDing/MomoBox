package httpapi

import (
	"net/http"
	"strconv"
	"strings"

	syncservice "github.com/momobox/backend/internal/sync"
)

func (h *Handler) bootstrap(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "sync", h.deps.Sync) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	deviceID, ok := currentDeviceID(w, r, claims, strings.TrimSpace(r.URL.Query().Get("device_id")))
	if !ok {
		return
	}
	response, err := h.deps.Sync.Bootstrap(r.Context(), syncservice.BootstrapRequest{DeviceID: deviceID})
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) confirmBootstrap(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "sync", h.deps.Sync) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	var request syncservice.BootstrapConfirmRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	deviceID, ok := currentDeviceID(w, r, claims, request.DeviceID)
	if !ok {
		return
	}
	request.DeviceID = deviceID
	response, err := h.deps.Sync.ConfirmBootstrap(r.Context(), request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) push(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "sync", h.deps.Sync) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	var request syncservice.PushRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	deviceID, ok := currentDeviceID(w, r, claims, request.DeviceID)
	if !ok {
		return
	}
	request.DeviceID = deviceID
	response, err := h.deps.Sync.Push(r.Context(), request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) pull(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "sync", h.deps.Sync) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	cursor, err := parseInt64Query(r, "cursor")
	if err != nil || cursor < 0 {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "cursor must be a non-negative integer", nil)
		return
	}
	limit := 100
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > 500 {
			writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "limit must be between 1 and 500", nil)
			return
		}
	}
	deviceID, ok := currentDeviceID(w, r, claims, strings.TrimSpace(r.URL.Query().Get("device_id")))
	if !ok {
		return
	}
	response, err := h.deps.Sync.Pull(r.Context(), syncservice.PullRequest{DeviceID: deviceID, Cursor: cursor, Limit: limit})
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}
