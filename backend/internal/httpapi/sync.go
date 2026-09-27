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

func (h *Handler) conflicts(w http.ResponseWriter, r *http.Request) {
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
	limit := 0
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 200 {
			writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "limit must be between 1 and 200", nil)
			return
		}
		limit = parsed
	}
	offset := 0
	if raw := strings.TrimSpace(r.URL.Query().Get("offset")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 0 {
			writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "offset must be a non-negative integer", nil)
			return
		}
		offset = parsed
	}
	status := syncservice.ConflictStatus(strings.TrimSpace(r.URL.Query().Get("status")))
	response, err := h.deps.Sync.ListConflicts(r.Context(), syncservice.ConflictListRequest{
		DeviceID: deviceID, Status: status, Limit: limit, Offset: offset,
	})
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) conflict(w http.ResponseWriter, r *http.Request) {
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
	conflictID := strings.TrimSpace(r.PathValue("conflict_id"))
	if conflictID == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "conflict_id is required", nil)
		return
	}
	response, err := h.deps.Sync.GetConflict(r.Context(), deviceID, conflictID)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) resolveConflict(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "sync", h.deps.Sync) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	var request syncservice.ConflictResolveRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	deviceID, ok := currentDeviceID(w, r, claims, request.DeviceID)
	if !ok {
		return
	}
	request.DeviceID = deviceID
	request.ConflictID = strings.TrimSpace(r.PathValue("conflict_id"))
	if request.ConflictID == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "conflict_id is required", nil)
		return
	}
	response, err := h.deps.Sync.ResolveConflict(r.Context(), request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}
