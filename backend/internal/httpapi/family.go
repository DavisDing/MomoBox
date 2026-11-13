package httpapi

import (
	"context"
	"net/http"

	"github.com/momobox/backend/internal/family"
)

func (h *Handler) initializeFamily(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "family", h.deps.Family) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	service, ok := h.deps.Family.(interface {
		Initialize(context.Context, string) (family.FamilyResponse, error)
	})
	if !ok {
		writeError(w, r, 503, "SERVICE_UNAVAILABLE", "family initialization unavailable", nil)
		return
	}
	result, err := service.Initialize(r.Context(), claims.UserID)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, 200, result)
}

func (h *Handler) createFamily(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "family", h.deps.Family) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	var request family.CreateFamilyRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	response, err := h.deps.Family.CreateFamily(r.Context(), claims.UserID, request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, response)
}

func (h *Handler) currentFamily(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "family", h.deps.Family) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	response, err := h.deps.Family.CurrentFamily(r.Context(), claims.UserID)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) createInvite(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "family", h.deps.Family) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	var request family.CreateInviteRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	response, err := h.deps.Family.CreateInvite(r.Context(), claims.UserID, claims.FamilyID, request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, response)
}

func (h *Handler) joinFamily(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "family", h.deps.Family) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	var request family.JoinFamilyRequest
	if !h.decodeJSON(w, r, &request) {
		return
	}
	response, err := h.deps.Family.Join(r.Context(), claims.UserID, request)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) listMembers(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "family", h.deps.Family) {
		return
	}
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return
	}
	response, err := h.deps.Family.ListMembers(r.Context(), claims.UserID, claims.FamilyID)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}
