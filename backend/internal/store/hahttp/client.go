package hahttp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/momobox/backend/internal/homeassistant"
)

const (
	defaultTimeout          = 10 * time.Second
	defaultMaxResponseBytes = int64(2 << 20)
)

// Client is a Home Assistant REST client. It never accepts a raw service name
// or service_data map; Execute translates the domain's typed invocation into a
// fixed endpoint and fixed payload fields.
type Client struct {
	httpClient       *http.Client
	maxResponseBytes int64
	now              func() time.Time
}

var _ homeassistant.HAClient = (*Client)(nil)

func New(client *http.Client) *Client {
	if client == nil {
		client = &http.Client{Transport: http.DefaultTransport}
	}
	cloned := *client
	if cloned.Timeout <= 0 {
		cloned.Timeout = defaultTimeout
	}
	// Never follow redirects with an Authorization header. Home Assistant base
	// URLs are configured explicitly; a redirect must be fixed by an admin.
	cloned.CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return &Client{
		httpClient:       &cloned,
		maxResponseBytes: defaultMaxResponseBytes,
		now:              func() time.Time { return time.Now().UTC() },
	}
}

func (c *Client) Test(ctx context.Context, baseURL, accessToken string) (homeassistant.ConnectionResult, error) {
	var config struct {
		Version string `json:"version"`
	}
	status, err := c.request(ctx, http.MethodGet, baseURL, accessToken, []string{"api", "config"}, nil, &config)
	if err != nil {
		return homeassistant.ConnectionResult{}, err
	}
	switch status {
	case http.StatusOK:
		return homeassistant.ConnectionResult{Connected: true, ServerVersion: config.Version}, nil
	case http.StatusUnauthorized, http.StatusForbidden:
		return homeassistant.ConnectionResult{Connected: false, ErrorCode: "invalid_credentials"}, nil
	default:
		return homeassistant.ConnectionResult{Connected: false, ErrorCode: "unavailable"}, nil
	}
}

func (c *Client) Discover(ctx context.Context, baseURL, accessToken string) (homeassistant.Discovery, error) {
	var states []stateResponse
	status, err := c.request(ctx, http.MethodGet, baseURL, accessToken, []string{"api", "states"}, nil, &states)
	if err != nil {
		return homeassistant.Discovery{}, err
	}
	if status < 200 || status >= 300 {
		return homeassistant.Discovery{}, statusError(status)
	}

	devicesByID := make(map[string]homeassistant.DiscoveredDevice)
	entities := make([]homeassistant.DiscoveredEntity, 0, len(states))
	for _, state := range states {
		domain, ok := entityDomain(state.EntityID)
		if !ok {
			continue
		}
		deviceID := attributeString(state.Attributes, "device_id")
		if deviceID != "" {
			if _, exists := devicesByID[deviceID]; !exists {
				devicesByID[deviceID] = homeassistant.DiscoveredDevice{
					HADeviceID:   deviceID,
					Name:         firstNonEmpty(attributeString(state.Attributes, "device_name"), attributeString(state.Attributes, "friendly_name"), deviceID),
					AreaName:     firstNonEmpty(attributeString(state.Attributes, "area_name"), attributeString(state.Attributes, "area_id")),
					Manufacturer: attributeString(state.Attributes, "manufacturer"),
					Model:        attributeString(state.Attributes, "model"),
				}
			}
		}
		entities = append(entities, homeassistant.DiscoveredEntity{
			EntityID:       state.EntityID,
			HADeviceID:     deviceID,
			Domain:         domain,
			Name:           firstNonEmpty(attributeString(state.Attributes, "friendly_name"), state.EntityID),
			AreaName:       firstNonEmpty(attributeString(state.Attributes, "area_name"), attributeString(state.Attributes, "area_id")),
			Capabilities:   deriveCapabilities(domain, state.Attributes),
			HVACModes:      attributeStrings(state.Attributes, "hvac_modes"),
			TemperatureMin: attributeFloat(state.Attributes, "min_temp"),
			TemperatureMax: attributeFloat(state.Attributes, "max_temp"),
			CurrentState:   state.State,
		})
	}
	devices := make([]homeassistant.DiscoveredDevice, 0, len(devicesByID))
	for _, device := range devicesByID {
		devices = append(devices, device)
	}
	return homeassistant.Discovery{Devices: devices, Entities: entities}, nil
}

func (c *Client) GetState(ctx context.Context, baseURL, accessToken string, entity homeassistant.HAEntity) (homeassistant.HAState, error) {
	if _, ok := entityDomain(entity.EntityID); !ok {
		return homeassistant.HAState{}, errors.New("invalid Home Assistant entity ID")
	}
	var state stateResponse
	status, err := c.request(ctx, http.MethodGet, baseURL, accessToken, []string{"api", "states", entity.EntityID}, nil, &state)
	if err != nil {
		return homeassistant.HAState{}, err
	}
	if status < 200 || status >= 300 {
		return homeassistant.HAState{}, statusError(status)
	}
	return toHAState(state, c.now()), nil
}

func (c *Client) Execute(ctx context.Context, baseURL, accessToken string, invocation homeassistant.CommandInvocation) (homeassistant.CommandResult, error) {
	domain, service, payload, err := typedServiceCall(invocation)
	if err != nil {
		return homeassistant.CommandResult{}, err
	}
	var states []stateResponse
	status, err := c.request(ctx, http.MethodPost, baseURL, accessToken, []string{"api", "services", domain, service}, payload, &states)
	if err != nil {
		return homeassistant.CommandResult{}, err
	}
	if status < 200 || status >= 300 {
		return homeassistant.CommandResult{Accepted: false}, statusError(status)
	}
	for _, state := range states {
		if state.EntityID == invocation.EntityID {
			converted := toHAState(state, c.now())
			return homeassistant.CommandResult{Accepted: true, State: &converted}, nil
		}
	}
	return homeassistant.CommandResult{Accepted: true}, nil
}

type serviceCallPayload struct {
	EntityID      string   `json:"entity_id"`
	BrightnessPct *int     `json:"brightness_pct,omitempty"`
	Temperature   *float64 `json:"temperature,omitempty"`
	HVACMode      string   `json:"hvac_mode,omitempty"`
}

func typedServiceCall(invocation homeassistant.CommandInvocation) (string, string, serviceCallPayload, error) {
	domain := strings.ToLower(strings.TrimSpace(invocation.Domain))
	entityDomainValue, ok := entityDomain(invocation.EntityID)
	if !ok || domain == "" || domain != entityDomainValue {
		return "", "", serviceCallPayload{}, errors.New("Home Assistant invocation domain does not match entity ID")
	}
	payload := serviceCallPayload{EntityID: invocation.EntityID}
	parameters := invocation.Parameters

	noParameters := func() bool {
		return parameters.Brightness == nil && parameters.Temperature == nil && parameters.HVACMode == ""
	}
	switch invocation.Command {
	case homeassistant.CommandTurnOn:
		if !allowedDomain(domain, "light", "switch", "fan", "climate", "media_player", "input_boolean") || !noParameters() {
			return "", "", serviceCallPayload{}, errors.New("invalid typed turn_on invocation")
		}
		return domain, "turn_on", payload, nil
	case homeassistant.CommandTurnOff:
		if !allowedDomain(domain, "light", "switch", "fan", "climate", "media_player", "input_boolean") || !noParameters() {
			return "", "", serviceCallPayload{}, errors.New("invalid typed turn_off invocation")
		}
		return domain, "turn_off", payload, nil
	case homeassistant.CommandToggle:
		if !allowedDomain(domain, "light", "switch", "fan", "input_boolean") || !noParameters() {
			return "", "", serviceCallPayload{}, errors.New("invalid typed toggle invocation")
		}
		return domain, "toggle", payload, nil
	case homeassistant.CommandSetBrightness:
		if domain != "light" || parameters.Brightness == nil || parameters.Temperature != nil || parameters.HVACMode != "" || *parameters.Brightness < 0 || *parameters.Brightness > 100 {
			return "", "", serviceCallPayload{}, errors.New("invalid typed set_brightness invocation")
		}
		payload.BrightnessPct = parameters.Brightness
		return "light", "turn_on", payload, nil
	case homeassistant.CommandSetTemperature:
		if domain != "climate" || parameters.Temperature == nil || parameters.Brightness != nil || parameters.HVACMode != "" || *parameters.Temperature < -100 || *parameters.Temperature > 200 {
			return "", "", serviceCallPayload{}, errors.New("invalid typed set_temperature invocation")
		}
		payload.Temperature = parameters.Temperature
		return "climate", "set_temperature", payload, nil
	case homeassistant.CommandSetHVACMode:
		if domain != "climate" || parameters.HVACMode == "" || len(parameters.HVACMode) > 64 || strings.ContainsAny(parameters.HVACMode, "\r\n") || parameters.Brightness != nil || parameters.Temperature != nil {
			return "", "", serviceCallPayload{}, errors.New("invalid typed set_hvac_mode invocation")
		}
		payload.HVACMode = parameters.HVACMode
		return "climate", "set_hvac_mode", payload, nil
	case homeassistant.CommandPlay:
		if domain != "media_player" || !noParameters() {
			return "", "", serviceCallPayload{}, errors.New("invalid typed play invocation")
		}
		return "media_player", "media_play", payload, nil
	case homeassistant.CommandPause:
		if domain != "media_player" || !noParameters() {
			return "", "", serviceCallPayload{}, errors.New("invalid typed pause invocation")
		}
		return "media_player", "media_pause", payload, nil
	case homeassistant.CommandActivateScene:
		if domain != "scene" || !noParameters() {
			return "", "", serviceCallPayload{}, errors.New("invalid typed activate_scene invocation")
		}
		return "scene", "turn_on", payload, nil
	case homeassistant.CommandRunScript:
		if domain != "script" || !noParameters() {
			return "", "", serviceCallPayload{}, errors.New("invalid typed run_script invocation")
		}
		return "script", "turn_on", payload, nil
	default:
		return "", "", serviceCallPayload{}, errors.New("Home Assistant command is outside the fixed allowlist")
	}
}

func (c *Client) request(ctx context.Context, method, baseURL, accessToken string, pathSegments []string, requestBody any, responseBody any) (int, error) {
	if err := homeassistant.ValidateBaseURL(baseURL); err != nil {
		return 0, err
	}
	if err := homeassistant.ValidateAccessToken(accessToken); err != nil {
		return 0, err
	}
	endpoint, err := url.JoinPath(homeassistant.NormalizeBaseURL(baseURL), pathSegments...)
	if err != nil {
		return 0, errors.New("build Home Assistant endpoint")
	}

	var body io.Reader
	if requestBody != nil {
		encoded, encodeErr := json.Marshal(requestBody)
		if encodeErr != nil {
			return 0, fmt.Errorf("encode typed Home Assistant request: %w", encodeErr)
		}
		body = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return 0, errors.New("create Home Assistant request")
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(accessToken))
	req.Header.Set("Accept", "application/json")
	if requestBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	response, err := c.httpClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("perform Home Assistant request: %w", err)
	}
	defer response.Body.Close()
	limited := io.LimitReader(response.Body, c.maxResponseBytes+1)
	encodedResponse, err := io.ReadAll(limited)
	if err != nil {
		return 0, errors.New("read Home Assistant response")
	}
	if int64(len(encodedResponse)) > c.maxResponseBytes {
		return 0, errors.New("Home Assistant response exceeds size limit")
	}
	if responseBody != nil && response.StatusCode >= 200 && response.StatusCode < 300 && len(encodedResponse) > 0 {
		if err := json.Unmarshal(encodedResponse, responseBody); err != nil {
			return 0, errors.New("decode Home Assistant response")
		}
	}
	return response.StatusCode, nil
}

func statusError(status int) error {
	return fmt.Errorf("Home Assistant returned HTTP status %d", status)
}

func allowedDomain(actual string, allowed ...string) bool {
	for _, candidate := range allowed {
		if actual == candidate {
			return true
		}
	}
	return false
}

func entityDomain(entityID string) (string, bool) {
	if strings.TrimSpace(entityID) != entityID || strings.ContainsAny(entityID, " /\\\t\r\n") {
		return "", false
	}
	parts := strings.Split(entityID, ".")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", false
	}
	for _, value := range parts {
		for _, r := range value {
			if !((r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_') {
				return "", false
			}
		}
	}
	return parts[0], true
}
