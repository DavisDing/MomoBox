package homeassistant

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/momobox/backend/internal/sync"
)

const validSyncChangeID = "123e4567-e89b-12d3-a456-426614174000"

type syncRoleResolverStub struct {
	role     Role
	err      error
	calls    int
	familyID string
	userID   string
}

func (s *syncRoleResolverStub) ResolveSyncRole(_ context.Context, familyID, userID string) (Role, error) {
	s.calls++
	s.familyID = familyID
	s.userID = userID
	return s.role, s.err
}

type syncCommandServiceStub struct {
	result        CommandDTO
	err           error
	calls         int
	actor         Actor
	integrationID string
	entityID      string
	request       CommandRequest
}

func (s *syncCommandServiceStub) ExecuteCommand(_ context.Context, actor Actor, integrationID, entityID string, request CommandRequest) (CommandDTO, error) {
	s.calls++
	s.actor = actor
	s.integrationID = integrationID
	s.entityID = entityID
	s.request = request
	return s.result, s.err
}

func TestSyncExecutorExecutesTopLevelAllowlistedCommand(t *testing.T) {
	executedAt := time.Date(2026, 9, 20, 10, 11, 12, 0, time.UTC)
	fetchedAt := executedAt.Add(-time.Second)
	roles := &syncRoleResolverStub{role: RoleMember}
	service := &syncCommandServiceStub{result: CommandDTO{
		Accepted:   true,
		EntityID:   "light.kitchen",
		Command:    CommandSetBrightness,
		ExecutedAt: executedAt,
		State: &StateDTO{
			EntityID:   "light.kitchen",
			State:      "on",
			Attributes: map[string]any{"brightness": 204},
			FetchedAt:  fetchedAt,
		},
	}}

	result, err := NewSyncExecutor(service, roles).ExecuteHomeAssistantCommand(context.Background(), "family-1", "user-1", sync.SyncChange{
		ChangeID:      validSyncChangeID,
		Operation:     sync.OperationHomeAssistantCommand,
		IntegrationID: "integration-1",
		EntityID:      "light.kitchen",
		Command:       "set_brightness",
		Parameters:    map[string]any{"brightness": float64(80)},
	})
	if err != nil {
		t.Fatalf("ExecuteHomeAssistantCommand() error = %v", err)
	}
	if roles.calls != 1 || roles.familyID != "family-1" || roles.userID != "user-1" {
		t.Fatalf("role resolver calls = %d, family = %q, user = %q", roles.calls, roles.familyID, roles.userID)
	}
	if service.calls != 1 {
		t.Fatalf("service calls = %d, want 1", service.calls)
	}
	if service.integrationID != "integration-1" {
		t.Fatalf("integration id = %q", service.integrationID)
	}
	if want := (Actor{FamilyID: "family-1", UserID: "user-1", Role: RoleMember}); service.actor != want {
		t.Fatalf("actor = %#v, want %#v", service.actor, want)
	}
	if service.entityID != "light.kitchen" {
		t.Fatalf("entity id = %q", service.entityID)
	}
	if service.request.Command != CommandSetBrightness || service.request.RequestID != validSyncChangeID {
		t.Fatalf("request = %#v", service.request)
	}
	if service.request.Parameters.Brightness == nil || *service.request.Parameters.Brightness != 80 {
		t.Fatalf("brightness = %#v", service.request.Parameters.Brightness)
	}
	if result.Payload["accepted"] != true || result.Payload["entity_id"] != "light.kitchen" || result.Payload["command"] != "set_brightness" || result.Payload["executed_at"] != executedAt {
		t.Fatalf("result payload = %#v", result.Payload)
	}
	state, ok := result.Payload["state"].(map[string]any)
	if !ok {
		t.Fatalf("state type = %T", result.Payload["state"])
	}
	if state["entity_id"] != "light.kitchen" || state["state"] != "on" || state["fetched_at"] != fetchedAt {
		t.Fatalf("state = %#v", state)
	}
	if _, err := json.Marshal(result); err != nil {
		t.Fatalf("result is not JSON serializable: %v", err)
	}
}

func TestSyncExecutorRejectsInvalidCommandShapeBeforeDependencies(t *testing.T) {
	tests := []struct {
		name   string
		change sync.SyncChange
	}{
		{name: "wrong operation", change: syncTestChange(func(c *sync.SyncChange) { c.Operation = sync.OperationEntityUpsert })},
		{name: "missing integration id", change: syncTestChange(func(c *sync.SyncChange) { c.IntegrationID = "" })},
		{name: "missing entity id", change: syncTestChange(func(c *sync.SyncChange) { c.EntityID = "" })},
		{name: "missing command", change: syncTestChange(func(c *sync.SyncChange) { c.Command = "" })},
		{name: "missing change id", change: syncTestChange(func(c *sync.SyncChange) { c.ChangeID = "" })},
		{name: "entity mutation field", change: syncTestChange(func(c *sync.SyncChange) { c.Entity = "products" })},
		{name: "base version field", change: syncTestChange(func(c *sync.SyncChange) { c.BaseVersion = 1 })},
		{name: "payload field", change: syncTestChange(func(c *sync.SyncChange) { c.Payload = map[string]any{"domain": "light"} })},
		{name: "operation id field", change: syncTestChange(func(c *sync.SyncChange) { c.OperationID = "inventory-op" })},
		{name: "allocations field", change: syncTestChange(func(c *sync.SyncChange) {
			c.Allocations = []sync.InventoryAllocation{{BatchID: "batch-1", Quantity: 1}}
		})},
		{name: "entity id invalid", change: syncTestChange(func(c *sync.SyncChange) { c.EntityID = "invalid" })},
		{name: "unknown parameter", change: syncTestChange(func(c *sync.SyncChange) { c.Parameters = map[string]any{"transition": 1} })},
		{name: "domain parameter forbidden", change: syncTestChange(func(c *sync.SyncChange) { c.Parameters = map[string]any{"domain": "light"} })},
		{name: "service parameter forbidden", change: syncTestChange(func(c *sync.SyncChange) { c.Parameters = map[string]any{"service": "turn_on"} })},
		{name: "service data parameter forbidden", change: syncTestChange(func(c *sync.SyncChange) { c.Parameters = map[string]any{"service_data": map[string]any{}} })},
		{name: "brightness string", change: brightnessChange("80")},
		{name: "brightness fractional", change: brightnessChange(80.5)},
		{name: "temperature string", change: temperatureChange("22.5")},
		{name: "hvac mode bool", change: hvacChange(false)},
		{name: "invalid command", change: syncTestChange(func(c *sync.SyncChange) { c.Command = "call_service" })},
		{name: "invalid change id as request id", change: syncTestChange(func(c *sync.SyncChange) { c.ChangeID = "not-a-uuid" })},
		{name: "parameters invalid for command", change: syncTestChange(func(c *sync.SyncChange) { c.Parameters = map[string]any{"brightness": 10} })},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			roles := &syncRoleResolverStub{role: RoleMember}
			service := &syncCommandServiceStub{}
			_, err := NewSyncExecutor(service, roles).ExecuteHomeAssistantCommand(context.Background(), "family-1", "user-1", test.change)
			if err == nil {
				t.Fatal("ExecuteHomeAssistantCommand() error = nil")
			}
			var businessErr *BusinessError
			if !errors.As(err, &businessErr) {
				t.Fatalf("error type = %T, want *BusinessError", err)
			}
			if roles.calls != 0 || service.calls != 0 {
				t.Fatalf("invalid input called dependencies: roles=%d service=%d", roles.calls, service.calls)
			}
		})
	}
}

func TestSyncExecutorPropagatesRoleResolverError(t *testing.T) {
	wantErr := errors.New("role lookup failed")
	roles := &syncRoleResolverStub{err: wantErr}
	service := &syncCommandServiceStub{}

	_, err := NewSyncExecutor(service, roles).ExecuteHomeAssistantCommand(context.Background(), "family-1", "user-1", validTurnOnChange())
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if roles.calls != 1 || service.calls != 0 {
		t.Fatalf("calls: roles=%d service=%d", roles.calls, service.calls)
	}
}

func TestSyncExecutorPropagatesCommandServiceError(t *testing.T) {
	wantErr := errors.New("command failed")
	roles := &syncRoleResolverStub{role: RoleAdmin}
	service := &syncCommandServiceStub{err: wantErr}

	_, err := NewSyncExecutor(service, roles).ExecuteHomeAssistantCommand(context.Background(), "family-1", "user-1", validTurnOnChange())
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if roles.calls != 1 || service.calls != 1 {
		t.Fatalf("calls: roles=%d service=%d", roles.calls, service.calls)
	}
}

func TestSyncExecutorRejectsNonJSONState(t *testing.T) {
	roles := &syncRoleResolverStub{role: RoleOwner}
	service := &syncCommandServiceStub{result: CommandDTO{
		Accepted: true,
		EntityID: "light.kitchen",
		Command:  CommandTurnOn,
		State: &StateDTO{
			EntityID:   "light.kitchen",
			State:      "on",
			Attributes: map[string]any{"bad": make(chan int)},
		},
	}}

	_, err := NewSyncExecutor(service, roles).ExecuteHomeAssistantCommand(context.Background(), "family-1", "user-1", validTurnOnChange())
	if err == nil {
		t.Fatal("ExecuteHomeAssistantCommand() error = nil")
	}
}

func validTurnOnChange() sync.SyncChange {
	return sync.SyncChange{
		ChangeID:      validSyncChangeID,
		Operation:     sync.OperationHomeAssistantCommand,
		IntegrationID: "integration-1",
		EntityID:      "light.kitchen",
		Command:       "turn_on",
	}
}

func syncTestChange(mutate func(*sync.SyncChange)) sync.SyncChange {
	change := validTurnOnChange()
	mutate(&change)
	return change
}

func brightnessChange(value any) sync.SyncChange {
	return syncTestChange(func(change *sync.SyncChange) {
		change.Command = "set_brightness"
		change.Parameters = map[string]any{"brightness": value}
	})
}

func temperatureChange(value any) sync.SyncChange {
	return syncTestChange(func(change *sync.SyncChange) {
		change.Command = "set_temperature"
		change.Parameters = map[string]any{"temperature": value}
	})
}

func hvacChange(value any) sync.SyncChange {
	return syncTestChange(func(change *sync.SyncChange) {
		change.Command = "set_hvac_mode"
		change.Parameters = map[string]any{"hvac_mode": value}
	})
}

func TestSyncStatePayloadDoesNotExposeDTOFieldNames(t *testing.T) {
	state, err := syncStatePayload(&StateDTO{EntityID: "sensor.room", State: "21"})
	if err != nil {
		t.Fatal(err)
	}
	wantKeys := map[string]any{"entity_id": "sensor.room", "state": "21", "attributes": map[string]any{}, "fetched_at": time.Time{}}
	if !reflect.DeepEqual(state, wantKeys) {
		t.Fatalf("state = %#v, want %#v", state, wantKeys)
	}
}
