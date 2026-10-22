package httpapi

import (
	"context"
	"net/http"
	"strconv"
	"strings"

	syncdomain "github.com/momobox/backend/internal/sync"
)

// Keep the optional feature separate from legacy SyncService adapters.
type initialImportService interface {
	ImportCapabilities(context.Context, syncdomain.DeviceScope) (syncdomain.ImportCapabilities, error)
	PreflightImport(context.Context, syncdomain.DeviceScope, syncdomain.ImportRequest) (syncdomain.ImportReceipt, error)
	ConfirmImport(context.Context, syncdomain.DeviceScope, string, syncdomain.ImportConfirmRequest) (syncdomain.ImportReceipt, error)
	ImportReceipt(context.Context, syncdomain.DeviceScope, string) (syncdomain.ImportReceipt, error)
	ImportHistory(context.Context, syncdomain.DeviceScope, syncdomain.ImportHistoryRequest) (syncdomain.ImportHistoryPage, error)
}

func (h *Handler) importService(w http.ResponseWriter, r *http.Request) (initialImportService, syncdomain.DeviceScope, bool) {
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return nil, syncdomain.DeviceScope{}, false
	}
	device, ok := currentDeviceID(w, r, claims, strings.TrimSpace(r.URL.Query().Get("device_id")))
	if !ok {
		return nil, syncdomain.DeviceScope{}, false
	}
	service, ok := h.deps.Sync.(initialImportService)
	if !ok {
		writeError(w, r, http.StatusServiceUnavailable, "IMPORT_NOT_AVAILABLE", "initial import is not available", nil)
		return nil, syncdomain.DeviceScope{}, false
	}
	actor := syncdomain.DeviceScope{DeviceID: device, UserID: claims.UserID, FamilyID: claims.FamilyID}
	return service, actor, true
}

func (h *Handler) importCapabilities(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) {
		return
	}
	service, actor, ok := h.importService(w, r)
	if !ok {
		return
	}
	response, err := service.ImportCapabilities(r.Context(), actor)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) preflightImport(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) {
		return
	}
	service, actor, ok := h.importService(w, r)
	if !ok {
		return
	}
	// The feature limit is fixed even if ordinary request limits are larger.
	r.Body = http.MaxBytesReader(w, r.Body, syncdomain.MaxImportBytes)
	var request syncdomain.ImportRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	if request.DeviceID != "" && request.DeviceID != actor.DeviceID {
		writeError(w, r, http.StatusForbidden, "FORBIDDEN", "device does not match the access token", nil)
		return
	}
	request.DeviceID = actor.DeviceID
	response, err := service.PreflightImport(r.Context(), actor, request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) confirmImport(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) {
		return
	}
	service, actor, ok := h.importService(w, r)
	if !ok {
		return
	}
	var request syncdomain.ImportConfirmRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	if request.DeviceID != "" && request.DeviceID != actor.DeviceID {
		writeError(w, r, http.StatusForbidden, "FORBIDDEN", "device does not match the access token", nil)
		return
	}
	request.DeviceID = actor.DeviceID
	response, err := service.ConfirmImport(r.Context(), actor, r.PathValue("import_id"), request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) importReceipt(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) {
		return
	}
	service, actor, ok := h.importService(w, r)
	if !ok {
		return
	}
	response, err := service.ImportReceipt(r.Context(), actor, r.PathValue("import_id"))
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) importHistory(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) {
		return
	}
	service, actor, ok := h.importService(w, r)
	if !ok {
		return
	}
	request := syncdomain.ImportHistoryRequest{Limit: 100}
	for _, field := range []string{"after", "until", "limit"} {
		raw := r.URL.Query().Get(field)
		if raw == "" {
			continue
		}
		number, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || number < 0 {
			writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "history pagination is invalid", nil)
			return
		}
		switch field {
		case "after":
			request.After = number
		case "until":
			request.Until = number
		case "limit":
			if number < 1 || number > 500 {
				writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "history limit must be between 1 and 500", nil)
				return
			}
			request.Limit = int(number)
		}
	}
	response, err := service.ImportHistory(r.Context(), actor, request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}
