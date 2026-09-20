package sync_test

import (
	"context"
	"strings"
	"testing"

	syncmod "github.com/momobox/backend/internal/sync"
)

type fakeRepository struct {
	device       syncmod.DeviceScope
	bootstrap    syncmod.BootstrapSnapshot
	confirm      syncmod.BootstrapConfirmation
	entities     map[string]syncmod.EntityRecord
	idempotency  map[string]syncmod.IdempotencyRecord
	changes      []syncmod.ChangeLogEntry
	cursor       int64
	inventoryRun int
	haRun        int
}

func newFakeRepository() *fakeRepository {
	return &fakeRepository{
		device:      syncmod.DeviceScope{DeviceID: "device-1", FamilyID: "family-1"},
		entities:    map[string]syncmod.EntityRecord{},
		idempotency: map[string]syncmod.IdempotencyRecord{},
	}
}

func (f *fakeRepository) ResolveDevice(_ context.Context, deviceID string) (syncmod.DeviceScope, error) {
	if deviceID != f.device.DeviceID {
		return syncmod.DeviceScope{}, syncmod.ErrDeviceNotFound
	}
	return f.device, nil
}

func (f *fakeRepository) ReadBootstrap(_ context.Context, _ string) (syncmod.BootstrapSnapshot, error) {
	return f.bootstrap, nil
}

func (f *fakeRepository) ConfirmBootstrap(_ context.Context, _ string, _ syncmod.BootstrapConfirmRequest) (syncmod.BootstrapConfirmation, error) {
	return f.confirm, nil
}

func (f *fakeRepository) Pull(_ context.Context, _ string, cursor int64, limit int) (syncmod.PullPage, error) {
	result := make([]syncmod.ChangeLogEntry, 0, limit)
	for _, change := range f.changes {
		if change.Cursor > cursor && len(result) < limit {
			result = append(result, change)
		}
	}
	next := cursor
	if len(result) > 0 {
		next = result[len(result)-1].Cursor
	}
	return syncmod.PullPage{Changes: result, NextCursor: next, HasMore: next < f.cursor}, nil
}

func (f *fakeRepository) WithTransaction(_ context.Context, _ string, fn func(syncmod.SyncTransaction) error) error {
	return fn(f)
}

func (f *fakeRepository) GetEntity(_ context.Context, entity, entityID string) (syncmod.EntityRecord, error) {
	value, ok := f.entities[entity+":"+entityID]
	if !ok {
		return syncmod.EntityRecord{}, syncmod.ErrNotFound
	}
	return value, nil
}

func (f *fakeRepository) UpsertEntity(_ context.Context, mutation syncmod.EntityMutation) (syncmod.EntityRecord, error) {
	value := syncmod.EntityRecord{Entity: mutation.Entity, EntityID: mutation.EntityID, Version: mutation.BaseVersion + 1, Payload: mutation.Payload}
	f.entities[mutation.Entity+":"+mutation.EntityID] = value
	return value, nil
}

func (f *fakeRepository) DeleteEntity(_ context.Context, mutation syncmod.EntityMutation) (syncmod.EntityRecord, error) {
	value := syncmod.EntityRecord{Entity: mutation.Entity, EntityID: mutation.EntityID, Version: mutation.BaseVersion + 1, Payload: map[string]any{"deleted": true}}
	f.entities[mutation.Entity+":"+mutation.EntityID] = value
	return value, nil
}

func (f *fakeRepository) ExecuteInventoryCommand(_ context.Context, _ syncmod.SyncChange) (syncmod.InventoryCommandResult, error) {
	f.inventoryRun++
	return syncmod.InventoryCommandResult{EntityID: "batch-1", Version: 2, Payload: map[string]any{"operation": "recorded"}}, nil
}

func (f *fakeRepository) ExecuteHomeAssistantCommand(_ context.Context, _ syncmod.SyncChange) (syncmod.HomeAssistantCommandResult, error) {
	f.haRun++
	return syncmod.HomeAssistantCommandResult{Payload: map[string]any{"executed": true}}, nil
}

func (f *fakeRepository) GetIdempotency(_ context.Context, deviceID, key string) (syncmod.IdempotencyRecord, bool, error) {
	value, ok := f.idempotency[deviceID+":"+key]
	return value, ok, nil
}

func (f *fakeRepository) PutIdempotency(_ context.Context, deviceID, key string, record syncmod.IdempotencyRecord) error {
	f.idempotency[deviceID+":"+key] = record
	return nil
}

func (f *fakeRepository) AppendChange(_ context.Context, change syncmod.ChangeLogEntry) (syncmod.ChangeLogEntry, error) {
	f.cursor++
	change.Cursor = f.cursor
	f.changes = append(f.changes, change)
	return change, nil
}

func (f *fakeRepository) CurrentCursor(_ context.Context) (int64, error) {
	return f.cursor, nil
}

func (f *fakeRepository) RecordConflict(_ context.Context, _ syncmod.SyncConflict) error {
	return nil
}

func testChange(operation syncmod.Operation, key string) syncmod.SyncChange {
	return syncmod.SyncChange{
		ChangeID:       "change-1",
		Operation:      operation,
		Entity:         "products",
		EntityID:       "product-1",
		BaseVersion:    0,
		Payload:        map[string]any{"name": "洗衣液"},
		IdempotencyKey: key,
	}
}

func TestPushAcceptedThenReplayedWithoutSecondMutation(t *testing.T) {
	repository := newFakeRepository()
	service := syncmod.NewService(repository)
	request := syncmod.PushRequest{DeviceID: "device-1", Changes: []syncmod.SyncChange{testChange(syncmod.OperationEntityUpsert, "device-1:operation-1")}}

	first, err := service.Push(context.Background(), request)
	if err != nil {
		t.Fatalf("first push: %v", err)
	}
	if len(first.Accepted) != 1 || first.Accepted[0].ServerVersion != 1 {
		t.Fatalf("unexpected first response: %#v", first)
	}

	second, err := service.Push(context.Background(), request)
	if err != nil {
		t.Fatalf("replayed push: %v", err)
	}
	if len(second.Replayed) != 1 || second.Replayed[0].OriginalStatus != syncmod.PushStatusAccepted {
		t.Fatalf("expected replayed accepted result: %#v", second)
	}
	if second.Results[0].Status != syncmod.PushStatusReplayed {
		t.Fatalf("expected replayed status: %#v", second.Results[0])
	}
	if len(repository.changes) != 1 {
		t.Fatalf("replay appended another change: %d", len(repository.changes))
	}
}

func TestEntityConflictAndInventoryAreSeparatePaths(t *testing.T) {
	repository := newFakeRepository()
	repository.entities["products:product-1"] = syncmod.EntityRecord{
		Entity: "products", EntityID: "product-1", Version: 3, Payload: map[string]any{"name": "server"},
	}
	service := syncmod.NewService(repository)

	conflictRequest := syncmod.PushRequest{DeviceID: "device-1", Changes: []syncmod.SyncChange{{
		ChangeID: "conflict-1", Operation: syncmod.OperationEntityUpsert, Entity: "products", EntityID: "product-1",
		BaseVersion: 2, Payload: map[string]any{"name": "client"}, IdempotencyKey: "device-1:conflict-1",
	}}}
	conflict, err := service.Push(context.Background(), conflictRequest)
	if err != nil {
		t.Fatalf("conflict push: %v", err)
	}
	if len(conflict.Conflicts) != 1 || conflict.Conflicts[0].Reason != "VERSION_CONFLICT" {
		t.Fatalf("unexpected conflict: %#v", conflict)
	}

	inventoryRequest := syncmod.PushRequest{DeviceID: "device-1", Changes: []syncmod.SyncChange{{
		ChangeID: "inventory-1", Operation: syncmod.OperationInventoryCommand, Command: syncmod.InventoryCommandConsumeAllocated,
		Allocations:    []syncmod.InventoryAllocation{{BatchID: "batch-1", Quantity: 2}},
		IdempotencyKey: "device-1:inventory-1",
	}}}
	accepted, err := service.Push(context.Background(), inventoryRequest)
	if err != nil {
		t.Fatalf("inventory push: %v", err)
	}
	if len(accepted.Accepted) != 1 || repository.inventoryRun != 1 {
		t.Fatalf("inventory command did not use command path: %#v", accepted)
	}

	blocked := testChange(syncmod.OperationEntityUpsert, "device-1:quantity-1")
	blocked.Entity = syncmod.EntityProductBatches
	blocked.Payload = map[string]any{"quantity": 99}
	rejected, err := service.Push(context.Background(), syncmod.PushRequest{DeviceID: "device-1", Changes: []syncmod.SyncChange{blocked}})
	if err != nil {
		t.Fatalf("quantity overwrite push: %v", err)
	}
	if len(rejected.Rejected) != 1 || !strings.Contains(rejected.Rejected[0].Message, "inventory_command") {
		t.Fatalf("quantity overwrite was not rejected: %#v", rejected)
	}
}

func TestBootstrapAndPullExposeCursorContract(t *testing.T) {
	repository := newFakeRepository()
	repository.bootstrap = syncmod.BootstrapSnapshot{ServerCursor: 7, MergeRequired: true, Family: map[string]any{"id": "family-1"}}
	repository.confirm = syncmod.BootstrapConfirmation{Accepted: true, ServerCursor: 7}
	repository.changes = []syncmod.ChangeLogEntry{{ChangeID: "c1", Cursor: 8, Operation: syncmod.OperationEntityUpsert, Entity: "products", EntityID: "p1"}}
	repository.cursor = 8
	service := syncmod.NewService(repository)

	bootstrap, err := service.Bootstrap(context.Background(), syncmod.BootstrapRequest{DeviceID: "device-1"})
	if err != nil || bootstrap.ServerCursor != 7 || !bootstrap.MergeRequired || len(bootstrap.AvailableModes) != 3 {
		t.Fatalf("unexpected bootstrap: %#v, %v", bootstrap, err)
	}
	confirmed, err := service.ConfirmBootstrap(context.Background(), syncmod.BootstrapConfirmRequest{DeviceID: "device-1", Mode: syncmod.BootstrapModeJoinAndMerge})
	if err != nil || confirmed.NextAction != "pull_snapshot" {
		t.Fatalf("unexpected bootstrap confirmation: %#v, %v", confirmed, err)
	}
	pulled, err := service.Pull(context.Background(), syncmod.PullRequest{DeviceID: "device-1", Cursor: 7, Limit: 100})
	if err != nil || pulled.NextCursor != 8 || len(pulled.Changes) != 1 {
		t.Fatalf("unexpected pull: %#v, %v", pulled, err)
	}
}
