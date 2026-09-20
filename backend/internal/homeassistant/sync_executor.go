package homeassistant

import (
	"context"
	"encoding/json"
	"fmt"
	"math"

	"github.com/momobox/backend/internal/sync"
)

// SyncRoleResolver resolves the authenticated user's role in the family whose
// sync change is being processed. The role is never accepted from the payload.
type SyncRoleResolver interface {
	ResolveSyncRole(ctx context.Context, familyID, userID string) (Role, error)
}

// SyncCommandService is the narrow command surface required by sync.
type SyncCommandService interface {
	ExecuteCommand(context.Context, Actor, string, string, CommandRequest) (CommandDTO, error)
}

// SyncExecutor adapts a validated sync command to the Home Assistant service.
type SyncExecutor struct {
	service SyncCommandService
	roles   SyncRoleResolver
}

func NewSyncExecutor(service SyncCommandService, roles SyncRoleResolver) *SyncExecutor {
	return &SyncExecutor{service: service, roles: roles}
}

// ExecuteHomeAssistantCommand executes the fixed, allowlisted Home Assistant
// command shape accepted by sync. It deliberately has no raw domain, service,
// or service_data escape hatch.
func (e *SyncExecutor) ExecuteHomeAssistantCommand(ctx context.Context, familyID, userID string, change sync.SyncChange) (sync.HomeAssistantCommandResult, error) {
	if change.Operation != sync.OperationHomeAssistantCommand {
		return sync.HomeAssistantCommandResult{}, businessError(CodeInvalidArgument, "sync change is not a Home Assistant command", nil)
	}

	integrationID, entityID, request, err := decodeSyncCommand(change)
	if err != nil {
		return sync.HomeAssistantCommandResult{}, err
	}
	if err := validateIntegrationID(integrationID); err != nil {
		return sync.HomeAssistantCommandResult{}, err
	}
	if err := validateEntityID(entityID); err != nil {
		return sync.HomeAssistantCommandResult{}, err
	}
	if err := ValidateCommandRequest(request); err != nil {
		return sync.HomeAssistantCommandResult{}, err
	}
	if e == nil || e.roles == nil || e.service == nil {
		return sync.HomeAssistantCommandResult{}, businessError(CodeInvalidArgument, "sync Home Assistant executor is not configured", nil)
	}

	role, err := e.roles.ResolveSyncRole(ctx, familyID, userID)
	if err != nil {
		return sync.HomeAssistantCommandResult{}, err
	}
	actor := Actor{FamilyID: familyID, UserID: userID, Role: role}
	dto, err := e.service.ExecuteCommand(ctx, actor, integrationID, entityID, request)
	if err != nil {
		return sync.HomeAssistantCommandResult{}, err
	}

	state, err := syncStatePayload(dto.State)
	if err != nil {
		return sync.HomeAssistantCommandResult{}, err
	}
	return sync.HomeAssistantCommandResult{Payload: map[string]any{
		"accepted":    dto.Accepted,
		"entity_id":   dto.EntityID,
		"command":     string(dto.Command),
		"executed_at": dto.ExecutedAt,
		"state":       state,
	}}, nil
}

func decodeSyncCommand(change sync.SyncChange) (string, string, CommandRequest, error) {
	if change.IntegrationID == "" {
		return "", "", CommandRequest{}, invalidSyncPayload("integration_id is required")
	}
	if change.EntityID == "" {
		return "", "", CommandRequest{}, invalidSyncPayload("entity_id is required")
	}
	if change.Command == "" {
		return "", "", CommandRequest{}, invalidSyncPayload("command is required")
	}
	if change.ChangeID == "" {
		return "", "", CommandRequest{}, invalidSyncPayload("change_id is required")
	}

	// HA commands have their own top-level schema. Reject fields belonging to
	// entity mutations and inventory commands instead of silently ignoring them.
	if change.Entity != "" {
		return "", "", CommandRequest{}, invalidSyncPayload("entity is not allowed for home_assistant_command")
	}
	if change.BaseVersion != 0 {
		return "", "", CommandRequest{}, invalidSyncPayload("base_version is not allowed for home_assistant_command")
	}
	if change.Payload != nil {
		return "", "", CommandRequest{}, invalidSyncPayload("payload is not allowed for home_assistant_command")
	}
	if change.OperationID != "" {
		return "", "", CommandRequest{}, invalidSyncPayload("operation_id is not allowed for home_assistant_command")
	}
	if len(change.Allocations) != 0 {
		return "", "", CommandRequest{}, invalidSyncPayload("allocations are not allowed for home_assistant_command")
	}

	parameters := CommandParameters{}
	var err error
	if change.Parameters != nil {
		parameters, err = decodeSyncCommandParameters(change.Parameters)
		if err != nil {
			return "", "", CommandRequest{}, err
		}
	}

	return change.IntegrationID, change.EntityID, CommandRequest{
		Command:    Command(change.Command),
		Parameters: parameters,
		// The sync change ID is the stable UUID used by HA audit logging.
		RequestID: change.ChangeID,
	}, nil
}

func decodeSyncCommandParameters(payload map[string]any) (CommandParameters, error) {
	var result CommandParameters
	for key, raw := range payload {
		switch key {
		case "brightness":
			value, ok := losslessInt(raw)
			if !ok {
				return CommandParameters{}, invalidSyncPayload("parameters.brightness must be an integer")
			}
			result.Brightness = &value
		case "temperature":
			value, ok := finiteFloat64(raw)
			if !ok {
				return CommandParameters{}, invalidSyncPayload("parameters.temperature must be a number")
			}
			result.Temperature = &value
		case "hvac_mode":
			value, ok := raw.(string)
			if !ok {
				return CommandParameters{}, invalidSyncPayload("parameters.hvac_mode must be a string")
			}
			result.HVACMode = value
		default:
			return CommandParameters{}, invalidSyncPayload(fmt.Sprintf("unknown parameters field %q", key))
		}
	}
	return result, nil
}

func requiredString(payload map[string]any, key string) (string, error) {
	raw, ok := payload[key]
	if !ok {
		return "", invalidSyncPayload(key + " is required")
	}
	value, ok := raw.(string)
	if !ok {
		return "", invalidSyncPayload(key + " must be a string")
	}
	if value == "" {
		return "", invalidSyncPayload(key + " is required")
	}
	return value, nil
}

func losslessInt(value any) (int, bool) {
	var n int64
	switch value := value.(type) {
	case int:
		return value, true
	case int8:
		n = int64(value)
	case int16:
		n = int64(value)
	case int32:
		n = int64(value)
	case int64:
		n = value
	case uint:
		if uint64(value) > uint64(^uint(0)>>1) {
			return 0, false
		}
		return int(value), true
	case uint8:
		n = int64(value)
	case uint16:
		n = int64(value)
	case uint32:
		n = int64(value)
	case uint64:
		if value > uint64(^uint(0)>>1) {
			return 0, false
		}
		return int(value), true
	case float64:
		if math.IsNaN(value) || math.IsInf(value, 0) || math.Trunc(value) != value || value < float64(math.MinInt64) || value > float64(math.MaxInt64) {
			return 0, false
		}
		n = int64(value)
	case json.Number:
		parsed, err := value.Float64()
		if err != nil || math.IsNaN(parsed) || math.IsInf(parsed, 0) || math.Trunc(parsed) != parsed || parsed < float64(math.MinInt64) || parsed > float64(math.MaxInt64) {
			return 0, false
		}
		n = int64(parsed)
	default:
		return 0, false
	}
	converted := int(n)
	return converted, int64(converted) == n
}

func finiteFloat64(value any) (float64, bool) {
	var result float64
	switch value := value.(type) {
	case float64:
		result = value
	case float32:
		result = float64(value)
	case int:
		result = float64(value)
	case int8:
		result = float64(value)
	case int16:
		result = float64(value)
	case int32:
		result = float64(value)
	case int64:
		result = float64(value)
	case uint:
		result = float64(value)
	case uint8:
		result = float64(value)
	case uint16:
		result = float64(value)
	case uint32:
		result = float64(value)
	case uint64:
		result = float64(value)
	case json.Number:
		parsed, err := value.Float64()
		if err != nil {
			return 0, false
		}
		result = parsed
	default:
		return 0, false
	}
	return result, !math.IsNaN(result) && !math.IsInf(result, 0)
}

func syncStatePayload(state *StateDTO) (any, error) {
	if state == nil {
		return nil, nil
	}
	attributes := map[string]any{}
	if state.Attributes != nil {
		encoded, err := json.Marshal(state.Attributes)
		if err != nil {
			return nil, businessError(CodeInvalidArgument, "Home Assistant command state is not JSON serializable", err)
		}
		if err := json.Unmarshal(encoded, &attributes); err != nil {
			return nil, businessError(CodeInvalidArgument, "Home Assistant command state is not JSON serializable", err)
		}
	}
	return map[string]any{
		"entity_id":  state.EntityID,
		"state":      state.State,
		"attributes": attributes,
		"fetched_at": state.FetchedAt,
	}, nil
}

func invalidSyncPayload(message string) error {
	return businessError(CodeInvalidArgument, message, nil)
}
