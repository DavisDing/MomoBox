package httpapi

import (
	"net/http"

	"github.com/momobox/backend/internal/syncdevice"
)

func (h *Handler) devicesRoute(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		h.registerDevice(w, r)
	case http.MethodGet:
		h.listDevices(w, r)
	default:
		h.method(w, r, http.MethodGet+", "+http.MethodPost)
	}
}

func (h *Handler) registerDevice(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "devices", h.deps.Devices) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	var request syncdevice.RegisterDeviceRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	actor, _ := h.actor(claims)
	response, err := h.deps.Devices.Register(r.Context(), actor, request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, response)
}

func (h *Handler) listDevices(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "devices", h.deps.Devices) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	actor, _ := h.actor(claims)
	response, err := h.deps.Devices.ListResponse(r.Context(), actor)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) revokeDevice(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodDelete) || !h.requireService(w, r, "devices", h.deps.Devices) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	deviceID := r.PathValue("device_id")
	if deviceID == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "device_id is required", nil)
		return
	}
	actor, _ := h.actor(claims)
	if err := h.deps.Devices.Revoke(r.Context(), actor, deviceID); err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeNoContent(w)
}
