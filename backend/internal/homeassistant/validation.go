package homeassistant

import (
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"
)

func validateActor(a Actor) error {
	if !a.valid() {
		return businessError(CodeUnauthorized, "authenticated family member is required", nil)
	}
	return nil
}

func validateName(name string) error {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 120 {
		return businessError(CodeInvalidArgument, "name must be 1-120 characters", nil)
	}
	return nil
}

// ValidateBaseURL rejects credentials, query strings and fragments. It does
// not resolve DNS or make a network request; an HTTP adapter may add a network
// policy appropriate for its deployment.
func ValidateBaseURL(raw string) error {
	value := strings.TrimSpace(raw)
	if value == "" || len(value) > 2048 {
		return businessError(CodeInvalidURL, "base_url must be a valid Home Assistant URL", nil)
	}
	u, err := url.Parse(value)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return businessError(CodeInvalidURL, "base_url must use http or https without credentials, query, or fragment", err)
	}
	if u.Path != "" && u.Path != "/" {
		return businessError(CodeInvalidURL, "base_url must not contain a path", nil)
	}
	if u.Hostname() == "" {
		return businessError(CodeInvalidURL, "base_url must include a host", nil)
	}
	if port := u.Port(); port != "" {
		p, err := strconv.Atoi(port)
		if err != nil || p < 1 || p > 65535 {
			return businessError(CodeInvalidURL, "base_url contains an invalid port", err)
		}
	}
	// Reject malformed bracketed/IP hosts while allowing local DNS names and
	// private LAN addresses.
	if strings.Contains(u.Hostname(), "[") || strings.Contains(u.Hostname(), "]") {
		if net.ParseIP(strings.Trim(u.Hostname(), "[]")) == nil {
			return businessError(CodeInvalidURL, "base_url contains an invalid host", nil)
		}
	}
	return nil
}

func NormalizeBaseURL(raw string) string { return strings.TrimRight(strings.TrimSpace(raw), "/") }

func ValidateAccessToken(token string) error {
	value := strings.TrimSpace(token)
	if len(value) < 16 || len(value) > 4096 {
		return businessError(CodeInvalidToken, "access_token length is invalid", nil)
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return businessError(CodeInvalidToken, "access_token contains control characters", nil)
		}
	}
	return nil
}

func validateIntegrationID(id string) error {
	if strings.TrimSpace(id) == "" {
		return businessError(CodeInvalidArgument, "integration_id is required", nil)
	}
	return nil
}

func validateEntityID(id string) error {
	value := strings.TrimSpace(id)
	if value == "" || len(value) > 255 || !strings.Contains(value, ".") || strings.ContainsAny(value, " \t\r\n") {
		return businessError(CodeInvalidArgument, "entity_id is invalid", nil)
	}
	return nil
}

func validateUUIDLike(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, r := range value {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if r != '-' {
				return false
			}
			continue
		}
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
			return false
		}
	}
	return true
}

func validateCommandRequest(req CommandRequest) error {
	if !req.Command.Valid() {
		return businessError(CodeInvalidCommand, "command is not allowed", nil)
	}
	if !validateUUIDLike(req.RequestID) {
		return businessError(CodeInvalidArgument, "request_id must be a UUID", nil)
	}
	p := req.Parameters
	switch req.Command {
	case CommandSetBrightness:
		if p.Brightness == nil || p.Temperature != nil || p.HVACMode != "" {
			return businessError(CodeInvalidParameters, "set_brightness requires only brightness", nil)
		}
		if *p.Brightness < 0 || *p.Brightness > 100 {
			return businessError(CodeInvalidParameters, "brightness must be between 0 and 100", nil)
		}
	case CommandSetTemperature:
		if p.Temperature == nil || p.Brightness != nil || p.HVACMode != "" {
			return businessError(CodeInvalidParameters, "set_temperature requires only temperature", nil)
		}
		if *p.Temperature < -100 || *p.Temperature > 200 {
			return businessError(CodeInvalidParameters, "temperature is outside the supported safety range", nil)
		}
	case CommandSetHVACMode:
		if p.HVACMode == "" || p.Brightness != nil || p.Temperature != nil || len(p.HVACMode) > 64 || strings.ContainsAny(p.HVACMode, "\r\n") {
			return businessError(CodeInvalidParameters, "set_hvac_mode requires only hvac_mode", nil)
		}
	default:
		if p.Brightness != nil || p.Temperature != nil || p.HVACMode != "" {
			return businessError(CodeInvalidParameters, "command does not accept parameters", nil)
		}
	}
	return nil
}

func commandAllowedForEntity(entity HAEntity, command Command, p CommandParameters) bool {
	if !entity.IsControllable || !command.Valid() {
		return false
	}
	if command == CommandActivateScene {
		return entity.Domain == "scene"
	}
	if command == CommandRunScript {
		return entity.Domain == "script"
	}
	caps := make(map[string]struct{}, len(entity.Capabilities))
	for _, cap := range entity.Capabilities {
		caps[strings.ToLower(strings.TrimSpace(cap))] = struct{}{}
	}
	has := func(values ...string) bool {
		for _, value := range values {
			if _, ok := caps[value]; ok {
				return true
			}
		}
		return false
	}
	switch command {
	case CommandTurnOn, CommandTurnOff:
		return has(string(command), "on_off", "power", "switch")
	case CommandToggle:
		return has("toggle", "on_off", "power", "switch")
	case CommandSetBrightness:
		return has("brightness") && p.Brightness != nil
	case CommandSetTemperature:
		if !has("temperature", "temperature_control") || p.Temperature == nil {
			return false
		}
		if entity.TemperatureMin != nil && *p.Temperature < *entity.TemperatureMin {
			return false
		}
		if entity.TemperatureMax != nil && *p.Temperature > *entity.TemperatureMax {
			return false
		}
		return true
	case CommandSetHVACMode:
		if entity.Domain != "climate" || !has("hvac_mode", "hvac_modes") || p.HVACMode == "" || len(entity.HVACModes) == 0 {
			return false
		}
		for _, mode := range entity.HVACModes {
			if strings.EqualFold(mode, p.HVACMode) {
				return true
			}
		}
		return false
	case CommandPlay:
		return entity.Domain == "media_player" && has("play", "media_playback", "play_pause")
	case CommandPause:
		return entity.Domain == "media_player" && has("pause", "media_playback", "play_pause")
	}
	return false
}

func commandInPermission(command Command, allowed []Command) bool {
	for _, value := range allowed {
		if value == command {
			return true
		}
	}
	return false
}

func safeParameters(p CommandParameters) map[string]any {
	result := map[string]any{}
	if p.Brightness != nil {
		result["brightness"] = *p.Brightness
	}
	if p.Temperature != nil {
		result["temperature"] = *p.Temperature
	}
	if p.HVACMode != "" {
		result["hvac_mode"] = p.HVACMode
	}
	return result
}

// ValidateCommandRequest exposes the pure request validation for adapters and
// tests without exposing any raw Home Assistant service-call surface.
func ValidateCommandRequest(req CommandRequest) error { return validateCommandRequest(req) }

// IsAllowedCommand reports whether a command belongs to the fixed HA command
// allowlist.
func IsAllowedCommand(command Command) bool { return command.Valid() }
