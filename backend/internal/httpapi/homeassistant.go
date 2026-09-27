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

// Phase-four consumable linkage API.
type consumableGroupItemJSON struct {
	ID       string                  `json:"id,omitempty"`
	GroupID  string                  `json:"group_id,omitempty"`
	ProductID string                 `json:"product_id"`
	Quantity int                    `json:"quantity"`
	Unit     homeassistant.ConsumableUnit `json:"unit"`
}

type consumableGroupJSON struct {
	ID          string                    `json:"id,omitempty"`
	FamilyID    string                    `json:"family_id,omitempty"`
	Name        string                    `json:"name"`
	Description string                    `json:"description,omitempty"`
	Items       []consumableGroupItemJSON `json:"items"`
	CreatedAt   time.Time                 `json:"created_at,omitempty"`
	UpdatedAt   time.Time                 `json:"updated_at,omitempty"`
}

type consumableRecipeGroupJSON struct {
	ID       string                  `json:"id,omitempty"`
	RecipeID string                  `json:"recipe_id,omitempty"`
	GroupID  string                  `json:"group_id"`
	Quantity int                     `json:"quantity"`
	Unit     homeassistant.ConsumableUnit `json:"unit"`
}

type consumableRecipeJSON struct {
	ID          string                      `json:"id,omitempty"`
	FamilyID    string                      `json:"family_id,omitempty"`
	Name        string                      `json:"name"`
	Description string                      `json:"description,omitempty"`
	Groups      []consumableRecipeGroupJSON `json:"groups"`
	CreatedAt   time.Time                   `json:"created_at,omitempty"`
	UpdatedAt   time.Time                   `json:"updated_at,omitempty"`
}

type linkageRuleJSON struct {
	ID                   string `json:"id,omitempty"`
	FamilyID             string `json:"family_id,omitempty"`
	Name                 string `json:"name"`
	IntegrationID        string `json:"integration_id"`
	EntityID             string `json:"entity_id"`
	ApplianceDomain      string `json:"appliance_domain"`
	StartState           string `json:"start_state"`
	CompleteState        string `json:"complete_state"`
	RecipeID             string `json:"recipe_id"`
	Enabled              bool   `json:"enabled"`
	RequiresConfirmation bool   `json:"requires_confirmation"`
	CreatedAt            time.Time `json:"created_at,omitempty"`
	UpdatedAt            time.Time `json:"updated_at,omitempty"`
}

type purchaseSuggestionJSON struct {
	ProductID   string                    `json:"product_id"`
	ProductName string                    `json:"product_name"`
	Quantity    int                       `json:"quantity"`
	Unit        homeassistant.ConsumableUnit `json:"unit"`
}

type linkageSuggestionJSON struct {
	ID                   string                    `json:"id"`
	FamilyID             string                    `json:"family_id"`
	RuleID               string                    `json:"rule_id"`
	RecipeID             string                    `json:"recipe_id"`
	ApplianceRunID       string                    `json:"appliance_run_id"`
	Status               homeassistant.LinkageSuggestionStatus `json:"status"`
	RequiresConfirmation bool                      `json:"requires_confirmation"`
	PurchaseSuggestions  []purchaseSuggestionJSON `json:"purchase_suggestions"`
	CreatedAt            time.Time                 `json:"created_at"`
	ResolvedAt           *time.Time                `json:"resolved_at,omitempty"`
	ResolvedBy           string                    `json:"resolved_by,omitempty"`
}

type haEventJSON struct {
	IntegrationID string         `json:"integration_id"`
	EntityID      string         `json:"entity_id"`
	ApplianceRunID string        `json:"appliance_run_id"`
	Domain        string         `json:"domain"`
	State         string         `json:"state"`
	PreviousState string         `json:"previous_state,omitempty"`
	OccurredAt    time.Time      `json:"occurred_at"`
	Attributes    map[string]any `json:"attributes,omitempty"`
}

type applianceRunJSON struct {
	ID             string     `json:"id"`
	FamilyID       string     `json:"family_id"`
	RuleID         string     `json:"rule_id"`
	ApplianceRunID string     `json:"appliance_run_id"`
	IntegrationID  string     `json:"integration_id"`
	EntityID       string     `json:"entity_id"`
	Domain         string     `json:"domain"`
	Status         string     `json:"status"`
	StartedAt      *time.Time `json:"started_at,omitempty"`
	CompletedAt    *time.Time `json:"completed_at,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

type eventProcessResponseJSON struct {
	Run        *applianceRunJSON      `json:"run,omitempty"`
	Suggestion *linkageSuggestionJSON `json:"suggestion,omitempty"`
	Duplicate  bool                   `json:"duplicate"`
	AuditID    string                 `json:"audit_id,omitempty"`
}

type resolveLinkageSuggestionJSON struct {
	Decision homeassistant.SuggestionDecision `json:"decision"`
}

func consumableGroupResponse(value homeassistant.ConsumableGroup) consumableGroupJSON {
	items := make([]consumableGroupItemJSON, 0, len(value.Items))
	for _, item := range value.Items {
		items = append(items, consumableGroupItemJSON{ID: item.ID, GroupID: item.GroupID, ProductID: item.ProductID, Quantity: item.Quantity, Unit: item.Unit})
	}
	return consumableGroupJSON{ID: value.ID, FamilyID: value.FamilyID, Name: value.Name, Description: value.Description, Items: items, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt}
}

func consumableGroupRequest(value consumableGroupJSON, id string) homeassistant.ConsumableGroup {
	items := make([]homeassistant.ConsumableGroupItem, 0, len(value.Items))
	for _, item := range value.Items {
		items = append(items, homeassistant.ConsumableGroupItem{ID: item.ID, GroupID: item.GroupID, ProductID: item.ProductID, Quantity: item.Quantity, Unit: item.Unit})
	}
	return homeassistant.ConsumableGroup{ID: id, FamilyID: value.FamilyID, Name: value.Name, Description: value.Description, Items: items, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt}
}

func consumableRecipeResponse(value homeassistant.ConsumableRecipe) consumableRecipeJSON {
	groups := make([]consumableRecipeGroupJSON, 0, len(value.Groups))
	for _, group := range value.Groups {
		groups = append(groups, consumableRecipeGroupJSON{ID: group.ID, RecipeID: group.RecipeID, GroupID: group.GroupID, Quantity: group.Quantity, Unit: group.Unit})
	}
	return consumableRecipeJSON{ID: value.ID, FamilyID: value.FamilyID, Name: value.Name, Description: value.Description, Groups: groups, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt}
}

func consumableRecipeRequest(value consumableRecipeJSON, id string) homeassistant.ConsumableRecipe {
	groups := make([]homeassistant.ConsumableRecipeGroup, 0, len(value.Groups))
	for _, group := range value.Groups {
		groups = append(groups, homeassistant.ConsumableRecipeGroup{ID: group.ID, RecipeID: group.RecipeID, GroupID: group.GroupID, Quantity: group.Quantity, Unit: group.Unit})
	}
	return homeassistant.ConsumableRecipe{ID: id, FamilyID: value.FamilyID, Name: value.Name, Description: value.Description, Groups: groups, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt}
}

func linkageRuleResponse(value homeassistant.LinkageRule) linkageRuleJSON {
	return linkageRuleJSON{ID: value.ID, FamilyID: value.FamilyID, Name: value.Name, IntegrationID: value.IntegrationID, EntityID: value.EntityID, ApplianceDomain: value.ApplianceDomain, StartState: value.StartState, CompleteState: value.CompleteState, RecipeID: value.RecipeID, Enabled: value.Enabled, RequiresConfirmation: value.RequiresConfirmation, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt}
}

func linkageRuleRequest(value linkageRuleJSON, id string) homeassistant.LinkageRule {
	return homeassistant.LinkageRule{ID: id, FamilyID: value.FamilyID, Name: value.Name, IntegrationID: value.IntegrationID, EntityID: value.EntityID, ApplianceDomain: value.ApplianceDomain, StartState: value.StartState, CompleteState: value.CompleteState, RecipeID: value.RecipeID, Enabled: value.Enabled, RequiresConfirmation: value.RequiresConfirmation, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt}
}

func linkageSuggestionResponse(value homeassistant.LinkageSuggestion) linkageSuggestionJSON {
	purchase := make([]purchaseSuggestionJSON, 0, len(value.PurchaseSuggestions))
	for _, item := range value.PurchaseSuggestions {
		purchase = append(purchase, purchaseSuggestionJSON{ProductID: item.ProductID, ProductName: item.ProductName, Quantity: item.Quantity, Unit: item.Unit})
	}
	return linkageSuggestionJSON{ID: value.ID, FamilyID: value.FamilyID, RuleID: value.RuleID, RecipeID: value.RecipeID, ApplianceRunID: value.ApplianceRunID, Status: value.Status, RequiresConfirmation: value.RequiresConfirmation, PurchaseSuggestions: purchase, CreatedAt: value.CreatedAt, ResolvedAt: value.ResolvedAt, ResolvedBy: value.ResolvedBy}
}

func eventProcessResponse(value homeassistant.EventProcessResult) eventProcessResponseJSON {
	response := eventProcessResponseJSON{Duplicate: value.Duplicate, AuditID: value.AuditID}
	if value.Run != nil {
		response.Run = &applianceRunJSON{ID: value.Run.ID, FamilyID: value.Run.FamilyID, RuleID: value.Run.RuleID, ApplianceRunID: value.Run.ApplianceRunID, IntegrationID: value.Run.IntegrationID, EntityID: value.Run.EntityID, Domain: value.Run.Domain, Status: value.Run.Status, StartedAt: value.Run.StartedAt, CompletedAt: value.Run.CompletedAt, CreatedAt: value.Run.CreatedAt, UpdatedAt: value.Run.UpdatedAt}
	}
	if value.Suggestion != nil {
		mapped := linkageSuggestionResponse(*value.Suggestion)
		response.Suggestion = &mapped
	}
	return response
}

func (h *Handler) listConsumableGroups(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	values, err := h.deps.HomeAssistant.ListConsumableGroups(r.Context(), actor); if err != nil { h.serviceError(w, r, err); return }
	result := make([]consumableGroupJSON, 0, len(values)); for _, value := range values { result = append(result, consumableGroupResponse(value)) }
	writeJSON(w, http.StatusOK, map[string]any{"groups": result})
}

func (h *Handler) saveConsumableGroup(w http.ResponseWriter, r *http.Request, id string) {
	if !h.method(w, r, r.Method) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	var input consumableGroupJSON; if !h.decodeJSON(w, r, &input) { return }
	value, err := h.deps.HomeAssistant.SaveConsumableGroup(r.Context(), actor, consumableGroupRequest(input, id)); if err != nil { h.serviceError(w, r, err); return }
	status := http.StatusOK; if r.Method == http.MethodPost { status = http.StatusCreated }
	writeJSON(w, status, map[string]any{"group": consumableGroupResponse(value)})
}

func (h *Handler) consumableGroupsRoute(w http.ResponseWriter, r *http.Request) {
	switch r.Method { case http.MethodGet: h.listConsumableGroups(w, r); case http.MethodPost: h.saveConsumableGroup(w, r, ""); default: h.method(w, r, http.MethodGet+", "+http.MethodPost) }
}
func (h *Handler) consumableGroupRoute(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.PathValue("group_id")); if id == "" { writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "group_id is required", nil); return }
	if r.Method == http.MethodPut { h.saveConsumableGroup(w, r, id); return }
	h.method(w, r, http.MethodPut)
}

func (h *Handler) listConsumableRecipes(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	values, err := h.deps.HomeAssistant.ListConsumableRecipes(r.Context(), actor); if err != nil { h.serviceError(w, r, err); return }
	result := make([]consumableRecipeJSON, 0, len(values)); for _, value := range values { result = append(result, consumableRecipeResponse(value)) }
	writeJSON(w, http.StatusOK, map[string]any{"recipes": result})
}
func (h *Handler) saveConsumableRecipe(w http.ResponseWriter, r *http.Request, id string) {
	if !h.method(w, r, r.Method) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	var input consumableRecipeJSON; if !h.decodeJSON(w, r, &input) { return }
	value, err := h.deps.HomeAssistant.SaveConsumableRecipe(r.Context(), actor, consumableRecipeRequest(input, id)); if err != nil { h.serviceError(w, r, err); return }
	status := http.StatusOK; if r.Method == http.MethodPost { status = http.StatusCreated }
	writeJSON(w, status, map[string]any{"recipe": consumableRecipeResponse(value)})
}
func (h *Handler) consumableRecipesRoute(w http.ResponseWriter, r *http.Request) {
	switch r.Method { case http.MethodGet: h.listConsumableRecipes(w, r); case http.MethodPost: h.saveConsumableRecipe(w, r, ""); default: h.method(w, r, http.MethodGet+", "+http.MethodPost) }
}
func (h *Handler) consumableRecipeRoute(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.PathValue("recipe_id")); if id == "" { writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "recipe_id is required", nil); return }
	if r.Method == http.MethodPut { h.saveConsumableRecipe(w, r, id); return }
	h.method(w, r, http.MethodPut)
}

func (h *Handler) listLinkageRules(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	values, err := h.deps.HomeAssistant.ListLinkageRules(r.Context(), actor); if err != nil { h.serviceError(w, r, err); return }
	result := make([]linkageRuleJSON, 0, len(values)); for _, value := range values { result = append(result, linkageRuleResponse(value)) }
	writeJSON(w, http.StatusOK, map[string]any{"rules": result})
}
func (h *Handler) saveLinkageRule(w http.ResponseWriter, r *http.Request, id string) {
	if !h.method(w, r, r.Method) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	var input linkageRuleJSON; if !h.decodeJSON(w, r, &input) { return }
	value, err := h.deps.HomeAssistant.SaveLinkageRule(r.Context(), actor, linkageRuleRequest(input, id)); if err != nil { h.serviceError(w, r, err); return }
	status := http.StatusOK; if r.Method == http.MethodPost { status = http.StatusCreated }
	writeJSON(w, status, map[string]any{"rule": linkageRuleResponse(value)})
}
func (h *Handler) linkageRulesRoute(w http.ResponseWriter, r *http.Request) {
	switch r.Method { case http.MethodGet: h.listLinkageRules(w, r); case http.MethodPost: h.saveLinkageRule(w, r, ""); default: h.method(w, r, http.MethodGet+", "+http.MethodPost) }
}
func (h *Handler) linkageRuleRoute(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.PathValue("rule_id")); if id == "" { writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "rule_id is required", nil); return }
	if r.Method == http.MethodPut { h.saveLinkageRule(w, r, id); return }
	h.method(w, r, http.MethodPut)
}

func parseLinkageSuggestionStatus(value string) (homeassistant.LinkageSuggestionStatus, bool) {
	switch strings.TrimSpace(value) {
	case "": return "", true
	case string(homeassistant.SuggestionPending): return homeassistant.SuggestionPending, true
	case string(homeassistant.SuggestionDeducted): return homeassistant.SuggestionDeducted, true
	case string(homeassistant.SuggestionIgnored): return homeassistant.SuggestionIgnored, true
	case string(homeassistant.SuggestionInsufficientStock): return homeassistant.SuggestionInsufficientStock, true
	default: return "", false
	}
}
func (h *Handler) listLinkageSuggestions(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodGet) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	status, valid := parseLinkageSuggestionStatus(r.URL.Query().Get("status")); if !valid { writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "status is invalid", nil); return }
	values, err := h.deps.HomeAssistant.ListLinkageSuggestions(r.Context(), actor, status); if err != nil { h.serviceError(w, r, err); return }
	result := make([]linkageSuggestionJSON, 0, len(values)); for _, value := range values { result = append(result, linkageSuggestionResponse(value)) }
	writeJSON(w, http.StatusOK, map[string]any{"suggestions": result})
}
func (h *Handler) resolveLinkageSuggestion(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	id := strings.TrimSpace(r.PathValue("suggestion_id")); if id == "" { writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "suggestion_id is required", nil); return }
	var input resolveLinkageSuggestionJSON; if !h.decodeJSON(w, r, &input) { return }
	if input.Decision != homeassistant.DecisionConfirm && input.Decision != homeassistant.DecisionIgnore { writeError(w, r, http.StatusBadRequest, "VALIDATION_FAILED", "decision must be confirm or ignore", nil); return }
	value, err := h.deps.HomeAssistant.ResolveLinkageSuggestion(r.Context(), actor, id, input.Decision); if err != nil { h.serviceError(w, r, err); return }
	writeJSON(w, http.StatusOK, map[string]any{"suggestion": linkageSuggestionResponse(value)})
}
func (h *Handler) linkageSuggestionsRoute(w http.ResponseWriter, r *http.Request) { h.listLinkageSuggestions(w, r) }

func (h *Handler) processHAEvent(w http.ResponseWriter, r *http.Request) {
	if !h.method(w, r, http.MethodPost) || !h.requireService(w, r, "home_assistant", h.deps.HomeAssistant) { return }
	actor, ok := h.haActor(w, r); if !ok { return }
	var input haEventJSON; if !h.decodeJSON(w, r, &input) { return }
	value, err := h.deps.HomeAssistant.ProcessHAEvent(r.Context(), actor, homeassistant.HAEvent{IntegrationID: input.IntegrationID, EntityID: input.EntityID, ApplianceRunID: input.ApplianceRunID, Domain: input.Domain, State: input.State, PreviousState: input.PreviousState, OccurredAt: input.OccurredAt, Attributes: input.Attributes}); if err != nil { h.serviceError(w, r, err); return }
	writeJSON(w, http.StatusOK, eventProcessResponse(value))
}
