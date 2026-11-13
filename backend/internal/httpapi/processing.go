package httpapi

import (
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/platform"
	"github.com/momobox/backend/internal/processing"
)

func (h *Handler) processingActor(w http.ResponseWriter, r *http.Request) (auth.AccessTokenClaims, bool) {
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return claims, false
	}
	if claims.FamilyID == "" || claims.DeviceID == "" {
		writeError(w, r, 403, "FORBIDDEN", "current family and device required", nil)
		return claims, false
	}
	if !h.requireService(w, r, "processing", h.deps.Processing) {
		return claims, false
	}
	return claims, true
}
func processingError(w http.ResponseWriter, r *http.Request, err error) {
	var catalog *processing.ModelCatalogError
	if errors.As(err, &catalog) {
		status := http.StatusBadGateway
		if catalog.Code == "AI_NOT_CONFIGURED" {
			status = http.StatusServiceUnavailable
		}
		if catalog.Code == "AI_MODELS_TIMEOUT" {
			status = http.StatusGatewayTimeout
		}
		// Upstream 401/403 must not trigger NAS session refresh in the client.
		writeError(w, r, status, catalog.Code, "NAS AI model discovery failed; check gateway configuration", nil)
		return
	}
	switch {
	case errors.Is(err, processing.ErrOutcomeUnknown):
		writeError(w, r, 409, "AI_RESULT_UNKNOWN", "original AI request result is unknown; review before explicitly starting a new request", nil)
	case errors.Is(err, processing.ErrInvalid):
		writeError(w, r, 400, "VALIDATION_FAILED", "invalid media or processing request", nil)
	case errors.Is(err, sql.ErrNoRows):
		writeError(w, r, 404, "NOT_FOUND", "media not found", nil)
	case errors.Is(err, processing.ErrConflict):
		writeError(w, r, 409, "MEDIA_CONFLICT", "media identity conflicts or was deleted", nil)
	case errors.Is(err, processing.ErrBusy):
		writeError(w, r, 409, "PROCESSING_BUSY", "processing in progress; retry later", nil)
	case errors.Is(err, processing.ErrUnavailable):
		writeError(w, r, 503, "PROCESSOR_UNAVAILABLE", "backend processor unavailable; check NAS configuration or retry manually", nil)
	default:
		writeError(w, r, 500, "PROCESSING_FAILED", "backend processing failed", nil)
	}
}
func (h *Handler) uploadMedia(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	var u processing.Upload
	if !h.decodeJSON(w, r, &u) {
		return
	}
	a, err := h.deps.Processing.Upload(r.Context(), claims.FamilyID, claims.UserID, u)
	if err != nil {
		processingError(w, r, err)
		return
	}
	a.Content = nil
	writeJSON(w, 200, a)
}
func (h *Handler) listMedia(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	assets, err := h.deps.Processing.List(r.Context(), claims.FamilyID, q.Get("entity_type"), q.Get("entity_id"), q.Get("after"))
	if err != nil {
		processingError(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"assets": assets})
}
func (h *Handler) getMedia(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	a, err := h.deps.Processing.Get(r.Context(), claims.FamilyID, r.PathValue("media_id"))
	if err != nil {
		processingError(w, r, err)
		return
	}
	if a.DeletedAt != nil {
		a.Content = nil
	}
	writeJSON(w, 200, a)
}
func (h *Handler) deleteMedia(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	err := h.deps.Processing.Delete(r.Context(), claims.FamilyID, r.PathValue("media_id"))
	if err != nil {
		processingError(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"deleted": true})
}
func (h *Handler) reassignMedia(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ProductID string `json:"product_id"`
	}
	if !h.decodeJSON(w, r, &body) {
		return
	}
	err := h.deps.Processing.Reassign(r.Context(), claims.FamilyID, r.PathValue("media_id"), body.ProductID)
	if err != nil {
		processingError(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"reassigned": true})
}
func (h *Handler) ocrMedia(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	a, err := h.deps.Processing.RunOCR(r.Context(), claims.FamilyID, r.PathValue("media_id"))
	if err != nil {
		processingError(w, r, err)
		return
	}
	a.Content = nil
	writeJSON(w, 200, a)
}
func (h *Handler) analyze(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	var body processing.AIRequest
	if !h.decodeJSON(w, r, &body) {
		return
	}
	out, err := h.deps.Processing.Analyze(r.Context(), claims.FamilyID, claims.UserID, body)
	if err != nil {
		processingError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
func (h *Handler) aiModels(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) {
		return
	}
	if _, ok := h.processingActor(w, r); !ok {
		return
	}
	started := time.Now()
	models, err := h.deps.Processing.AI.Models(r.Context())
	code, upstreamStatus := "OK", 0
	if err != nil {
		code = "AI_MODELS_FAILED"
		var catalog *processing.ModelCatalogError
		if errors.As(err, &catalog) {
			code, upstreamStatus = catalog.Code, catalog.UpstreamStatus
		}
	}
	slog.InfoContext(r.Context(), "ai_models_lookup", "request_id", platform.RequestIDFromContext(r.Context()),
		"result", code, "upstream_status", upstreamStatus, "model_count", len(models), "duration_ms", time.Since(started).Milliseconds())
	if err != nil {
		processingError(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"models": models})
}
func (h *Handler) operationHistory(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	after, e1 := strconv.ParseInt(q.Get("after"), 10, 64)
	until, e2 := strconv.ParseInt(q.Get("until"), 10, 64)
	limit, e3 := strconv.Atoi(q.Get("limit"))
	if e1 != nil || e2 != nil || e3 != nil {
		processingError(w, r, processing.ErrInvalid)
		return
	}
	out, err := h.deps.Processing.History(r.Context(), claims.FamilyID, after, until, limit)
	if err != nil {
		processingError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
func (h *Handler) searchManual(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) {
		return
	}
	claims, ok := h.processingActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ProductID string `json:"product_id"`
		Query     string `json:"query"`
	}
	if !h.decodeJSON(w, r, &body) {
		return
	}
	out, err := h.deps.Processing.SearchManual(r.Context(), claims.FamilyID, body.ProductID, body.Query)
	if err != nil {
		processingError(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"sources": out})
}
