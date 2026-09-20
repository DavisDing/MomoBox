package hahttp

import (
	"encoding/json"
	"time"

	"github.com/momobox/backend/internal/homeassistant"
)

type stateResponse struct {
	EntityID    string         `json:"entity_id"`
	State       string         `json:"state"`
	Attributes  map[string]any `json:"attributes"`
	LastChanged time.Time      `json:"last_changed"`
	LastUpdated time.Time      `json:"last_updated"`
}

func toHAState(state stateResponse, fetchedAt time.Time) homeassistant.HAState {
	attributes := make(map[string]any, len(state.Attributes))
	for key, value := range state.Attributes {
		attributes[key] = value
	}
	return homeassistant.HAState{
		EntityID:   state.EntityID,
		State:      state.State,
		Attributes: attributes,
		FetchedAt:  fetchedAt,
	}
}

func deriveCapabilities(domain string, attributes map[string]any) []string {
	capabilities := make([]string, 0, 6)
	appendCapability := func(values ...string) {
		capabilities = append(capabilities, values...)
	}
	switch domain {
	case "light":
		appendCapability("turn_on", "turn_off", "toggle")
		if _, ok := attributes["brightness"]; ok || len(attributeStrings(attributes, "supported_color_modes")) > 0 {
			appendCapability("brightness")
		}
	case "switch", "fan", "input_boolean":
		appendCapability("turn_on", "turn_off", "toggle")
	case "climate":
		appendCapability("turn_on", "turn_off")
		if attributeFloat(attributes, "min_temp") != nil || attributeFloat(attributes, "max_temp") != nil {
			appendCapability("temperature")
		}
		if len(attributeStrings(attributes, "hvac_modes")) > 0 {
			appendCapability("hvac_mode")
		}
	case "media_player":
		appendCapability("turn_on", "turn_off", "play", "pause")
	case "scene":
		appendCapability("activate_scene")
	case "script":
		appendCapability("run_script")
	}
	return capabilities
}

func attributeString(attributes map[string]any, key string) string {
	value, ok := attributes[key]
	if !ok {
		return ""
	}
	text, _ := value.(string)
	return text
}

func attributeStrings(attributes map[string]any, key string) []string {
	value, ok := attributes[key]
	if !ok {
		return nil
	}
	items, ok := value.([]any)
	if !ok {
		if typed, typedOK := value.([]string); typedOK {
			return append([]string(nil), typed...)
		}
		return nil
	}
	result := make([]string, 0, len(items))
	for _, item := range items {
		if text, ok := item.(string); ok && text != "" {
			result = append(result, text)
		}
	}
	return result
}

func attributeFloat(attributes map[string]any, key string) *float64 {
	value, ok := attributes[key]
	if !ok {
		return nil
	}
	switch number := value.(type) {
	case float64:
		copy := number
		return &copy
	case json.Number:
		parsed, err := number.Float64()
		if err == nil {
			return &parsed
		}
	}
	return nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
