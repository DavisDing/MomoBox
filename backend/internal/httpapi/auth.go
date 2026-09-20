package httpapi

import (
	"net/http"

	"github.com/momobox/backend/internal/auth"
)

func (h *Handler) register(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "auth", h.deps.Auth) {
		return
	}
	var request auth.RegisterRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	response, err := h.deps.Auth.Register(r.Context(), request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, response)
}

func (h *Handler) login(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "auth", h.deps.Auth) {
		return
	}
	var request auth.LoginRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	response, err := h.deps.Auth.Login(r.Context(), request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) refresh(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "auth", h.deps.Auth) {
		return
	}
	var request auth.RefreshRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	response, err := h.deps.Auth.Refresh(r.Context(), request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "auth", h.deps.Auth) {
		return
	}
	if _, _, ok := h.requireAuth(w, r); !ok {
		return
	}
	var request auth.RefreshRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	if err := h.deps.Auth.Logout(r.Context(), request); err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeNoContent(w)
}

func (h *Handler) me(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "auth", h.deps.Auth) {
		return
	}
	if _, token, ok := h.requireAuth(w, r); !ok {
		return
	} else {
		response, err := h.deps.Auth.CurrentUser(r.Context(), token)
		if err != nil {
			h.serviceError(w, r, err)
			return
		}
		writeJSON(w, http.StatusOK, response)
	}
}
