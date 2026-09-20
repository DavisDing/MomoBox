package httpapi

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	homeassistant "github.com/momobox/backend/internal/homeassistant"
)

type addIntegrationJSON struct {
	Name        string `json:"name"`
	BaseURL     string `json:"base_url"`
	AccessToken string `json:"access_token"`
}

type updateIntegrationJSON struct {
	Name        *string `json:"name"`
	BaseURL     *string `json:"base_url"`
	AccessToken *string `json:"access_token"`
	Enabled     *bool   `json:"enabled"`
}

type commandParametersJSON struct {
	Brightness  *int     `json:"brightness"`
	Temperature *float64 `json:"temperature"`
	HVACMode    string   `json:"hvac_mode"`
}

type commandJSON struct {
	Command    homeassistant.Command `json:"command"`
	Parameters commandParametersJSON `json:"parameters"`
	RequestID  string                `json:"request_id"`
}

type permissionJSON struct {
	IntegrationID   string                  `json:"integration_id"`
	EntityID        string                  `json:"entity_id"`
	Role            homeassistant.Role      `json:"role"`
	CanView         bool                    `json:"can_view"`
	CanControl      bool                    `json:"can_control"`
	AllowedCommands []homeassistant.Command `json:"allowed_commands"`
}

type integrationJSON struct {
	ID            string                          `json:"id"`
	Name          string                          `json:"name"`
	BaseURL       string                          `json:"base_url"`
	Status        homeassistant.IntegrationStatus `json:"status"`
	LastCheckedAt *time.Time                      `json:"last_checked_at,omitempty"`
	CreatedAt     time.Time                       `json:"created_at"`
	UpdatedAt     time.Time                       `json:"updated_at"`
	Enabled       bool                            `json:"enabled"`
}

type connectionTestJSON struct {
	Connected     bool      `json:"connected"`
	CheckedAt     time.Time `json:"checked_at"`
	ServerVersion string    `json:"server_version,omitempty"`
	ErrorCode     string    `json:"error_code,omitempty"`
}

type discoveryJSON struct {
	IntegrationID string `json:"integration_id"`
	Devices       int    `json:"devices"`
	Entities      int    `json:"entities"`
}

type entityJSON struct {
	ID             string     `json:"id"`
	IntegrationID  string     `json:"integration_id"`
	DeviceID       string     `json:"device_id,omitempty"`
	EntityID       string     `json:"entity_id"`
	Domain         string     `json:"domain"`
	Name           string     `json:"name"`
	AreaName       string     `json:"area_name,omitempty"`
	Capabilities   []string   `json:"capabilities,omitempty"`
	HVACModes      []string   `json:"hvac_modes,omitempty"`
	TemperatureMin *float64   `json:"temperature_min,omitempty"`
	TemperatureMax *float64   `json:"temperature_max,omitempty"`
	CurrentState   *string    `json:"current_state,omitempty"`
	IsVisible      bool       `json:"is_visible"`
	IsControllable bool       `json:"is_controllable"`
	LastStateAt    *time.Time `json:"last_state_at,omitempty"`
}

type stateJSON struct {
	EntityID   string         `json:"entity_id"`
	State      string         `json:"state"`
	Attributes map[string]any `json:"attributes,omitempty"`
	FetchedAt  time.Time      `json:"fetched_at"`
}

type commandResponseJSON struct {
	Accepted   bool                  `json:"accepted"`
	EntityID   string                `json:"entity_id"`
	Command    homeassistant.Command `json:"command"`
	ExecutedAt time.Time             `json:"executed_at"`
	State      *stateJSON            `json:"state,omitempty"`
}

type permissionResponseJSON struct {
	IntegrationID   string                  `json:"integration_id"`
	EntityID        string                  `json:"entity_id"`
	Role            homeassistant.Role      `json:"role"`
	CanView         bool                    `json:"can_view"`
	CanControl      bool                    `json:"can_control"`
	AllowedCommands []homeassistant.Command `json:"allowed_commands"`
}

func integrationResponse(value homeassistant.IntegrationDTO) integrationJSON {
	return integrationJSON{ID: value.ID, Name: value.Name, BaseURL: value.BaseURL, Status: value.Status, LastCheckedAt: value.LastCheckedAt, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt, Enabled: value.Enabled}
}

func stateResponse(value *homeassistant.StateDTO) *stateJSON {
	if value == nil {
		return nil
	}
	return &stateJSON{EntityID: value.EntityID, State: value.State, Attributes: value.Attributes, FetchedAt: value.FetchedAt}
}

func entityResponse(value homeassistant.EntityDTO) entityJSON {
	return entityJSON{ID: value.ID, IntegrationID: value.IntegrationID, DeviceID: value.DeviceID, EntityID: value.EntityID, Domain: value.Domain, Name: value.Name, AreaName: value.AreaName, Capabilities: value.Capabilities, HVACModes: value.HVACModes, TemperatureMin: value.TemperatureMin, TemperatureMax: value.TemperatureMax, CurrentState: value.CurrentState, IsVisible: value.IsVisible, IsControllable: value.IsControllable, LastStateAt: value.LastStateAt}
}

func permissionResponse(value homeassistant.PermissionDTO) permissionResponseJSON {
	return permissionResponseJSON{IntegrationID: value.IntegrationID, EntityID: value.EntityID, Role: value.Role, CanView: value.CanView, CanControl: value.CanControl, AllowedCommands: value.AllowedCommands}
}

func requiredIntegrationID(w http.ResponseWriter, r *http.Request) (string, bool) {
	integrationID := strings.TrimSpace(r.URL.Query().Get("integration_id"))
	if integrationID == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "integration_id query parameter is required", nil)
		return "", false
	}
	return integrationID, true
}

func (h *Handler) haActor(w http.ResponseWriter, r *http.Request) (homeassistant.Actor, bool) {
	claims, _, ok := h.requireAuth(w, r)
	if !ok {
		return homeassistant.Actor{}, false
	}
	_, actor := h.actor(claims)
	return actor, true
}

func (h *Handler) createIntegration(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	var input addIntegrationJSON
	if !h.decodeJSON(w, r, &input) {
		return
	}
	response, err := h.deps.HomeAssistant.CreateIntegration(r.Context(), actor, homeassistant.AddIntegrationRequest{Name: input.Name, BaseURL: input.BaseURL, AccessToken: input.AccessToken})
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, integrationResponse(response))
}

func (h *Handler) listIntegrations(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	values, err := h.deps.HomeAssistant.ListIntegrations(r.Context(), actor)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	result := make([]integrationJSON, 0, len(values))
	for _, value := range values {
		result = append(result, integrationResponse(value))
	}
	writeJSON(w, http.StatusOK, map[string]any{"integrations": result})
}

func (h *Handler) updateIntegration(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPatch) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(r.PathValue("integration_id"))
	if id == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "integration_id is required", nil)
		return
	}
	var input updateIntegrationJSON
	if !h.decodeJSON(w, r, &input) {
		return
	}
	response, err := h.deps.HomeAssistant.UpdateIntegration(r.Context(), actor, id, homeassistant.UpdateIntegrationRequest{Name: input.Name, BaseURL: input.BaseURL, AccessToken: input.AccessToken, Enabled: input.Enabled})
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, integrationResponse(response))
}

func (h *Handler) deleteIntegration(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodDelete) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(r.PathValue("integration_id"))
	if id == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "integration_id is required", nil)
		return
	}
	if err := h.deps.HomeAssistant.DeleteIntegration(r.Context(), actor, id); err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeNoContent(w)
}

func (h *Handler) testIntegration(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(r.PathValue("integration_id"))
	if id == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "integration_id is required", nil)
		return
	}
	value, err := h.deps.HomeAssistant.TestIntegration(r.Context(), actor, id)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, connectionTestJSON{Connected: value.Connected, CheckedAt: value.CheckedAt, ServerVersion: value.ServerVersion, ErrorCode: value.ErrorCode})
}

func (h *Handler) discover(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(r.PathValue("integration_id"))
	if id == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "integration_id is required", nil)
		return
	}
	value, err := h.deps.HomeAssistant.Discover(r.Context(), actor, id)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, discoveryJSON{IntegrationID: value.IntegrationID, Devices: value.Devices, Entities: value.Entities})
}

func (h *Handler) listEntities(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	controllable, err := strconv.ParseBool(r.URL.Query().Get("controllable_only"))
	if r.URL.Query().Get("controllable_only") == "" {
		controllable = false
		err = nil
	}
	if err != nil {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "controllable_only must be boolean", nil)
		return
	}
	values, err := h.deps.HomeAssistant.ListEntities(r.Context(), actor, strings.TrimSpace(r.URL.Query().Get("integration_id")), controllable)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	result := make([]entityJSON, 0, len(values))
	for _, value := range values {
		result = append(result, entityResponse(value))
	}
	writeJSON(w, http.StatusOK, map[string]any{"entities": result})
}

func (h *Handler) getState(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(r.PathValue("entity_id"))
	if id == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "entity_id is required", nil)
		return
	}
	integrationID, ok := requiredIntegrationID(w, r)
	if !ok {
		return
	}
	value, err := h.deps.HomeAssistant.GetState(r.Context(), actor, integrationID, id)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, stateResponse(&value))
}

func (h *Handler) executeCommand(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(r.PathValue("entity_id"))
	if id == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "entity_id is required", nil)
		return
	}
	integrationID, ok := requiredIntegrationID(w, r)
	if !ok {
		return
	}
	var input commandJSON
	if !h.decodeJSON(w, r, &input) {
		return
	}
	if strings.TrimSpace(input.RequestID) == "" {
		writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "request_id is required", nil)
		return
	}
	value, err := h.deps.HomeAssistant.ExecuteCommand(r.Context(), actor, integrationID, id, homeassistant.CommandRequest{Command: input.Command, Parameters: homeassistant.CommandParameters{Brightness: input.Parameters.Brightness, Temperature: input.Parameters.Temperature, HVACMode: input.Parameters.HVACMode}, RequestID: input.RequestID})
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, commandResponseJSON{Accepted: value.Accepted, EntityID: value.EntityID, Command: value.Command, ExecutedAt: value.ExecutedAt, State: stateResponse(value.State)})
}

func (h *Handler) listPermissions(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	values, err := h.deps.HomeAssistant.ListPermissions(r.Context(), actor)
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	result := make([]permissionResponseJSON, 0, len(values))
	for _, value := range values {
		result = append(result, permissionResponse(value))
	}
	writeJSON(w, http.StatusOK, map[string]any{"permissions": result})
}

func (h *Handler) updatePermission(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPut) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) {
		return
	}
	actor, ok := h.haActor(w, r)
	if !ok {
		return
	}
	var input permissionJSON
	if !h.decodeJSON(w, r, &input) {
		return
	}
	value, err := h.deps.HomeAssistant.UpdatePermission(r.Context(), actor, homeassistant.PermissionRequest{IntegrationID: input.IntegrationID, EntityID: input.EntityID, Role: input.Role, CanView: input.CanView, CanControl: input.CanControl, AllowedCommands: input.AllowedCommands})
	if err != nil {
		h.serviceError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, permissionResponse(value))
}

func (h *Handler) integrationsRoute(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		h.createIntegration(w, r)
	case http.MethodGet:
		h.listIntegrations(w, r)
	default:
		h.method(w, r, http.MethodGet+", "+http.MethodPost)
	}
}

func (h *Handler) integrationRoute(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPatch:
		h.updateIntegration(w, r)
	case http.MethodDelete:
		h.deleteIntegration(w, r)
	default:
		h.method(w, r, http.MethodPatch+", "+http.MethodDelete)
	}
}

func (h *Handler) permissionsRoute(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		h.listPermissions(w, r)
	case http.MethodPut:
		h.updatePermission(w, r)
	default:
		h.method(w, r, http.MethodGet+", "+http.MethodPut)
	}
}
