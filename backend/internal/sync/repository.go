package sync

import "context"

// Repository is the only persistence boundary needed by the sync business
// layer. HTTP handlers, SQL, authentication middleware and migrations are
// deliberately outside this package.
type Repository interface {
	ResolveDevice(ctx context.Context, deviceID string) (DeviceScope, error)
	ReadBootstrap(ctx context.Context, familyID string) (BootstrapSnapshot, error)
	ConfirmBootstrap(ctx context.Context, familyID string, request BootstrapConfirmRequest) (BootstrapConfirmation, error)
	Pull(ctx context.Context, familyID string, cursor int64, limit int) (PullPage, error)
	WithTransaction(ctx context.Context, familyID string, fn func(SyncTransaction) error) error
}

type PullPage struct {
	Changes    []ChangeLogEntry
	NextCursor int64
	HasMore    bool
}

// The smaller interfaces document responsibility splits and make it possible
// for a storage adapter to compose the transaction implementation from domain
// repositories without coupling the sync service to SQL tables.
type EntityRepository interface {
	GetEntity(ctx context.Context, entity, entityID string) (EntityRecord, error)
	UpsertEntity(ctx context.Context, mutation EntityMutation) (EntityRecord, error)
	DeleteEntity(ctx context.Context, mutation EntityMutation) (EntityRecord, error)
}

type InventoryRepository interface {
	ExecuteInventoryCommand(ctx context.Context, change SyncChange) (InventoryCommandResult, error)
}

type HomeAssistantRepository interface {
	ExecuteHomeAssistantCommand(ctx context.Context, change SyncChange) (HomeAssistantCommandResult, error)
}

type IdempotencyRepository interface {
	GetIdempotency(ctx context.Context, deviceID, key string) (IdempotencyRecord, bool, error)
	PutIdempotency(ctx context.Context, deviceID, key string, record IdempotencyRecord) error
}

type ChangeLogRepository interface {
	AppendChange(ctx context.Context, change ChangeLogEntry) (ChangeLogEntry, error)
	CurrentCursor(ctx context.Context) (int64, error)
}

type ConflictRepository interface {
	RecordConflict(ctx context.Context, conflict SyncConflict) error
}

type SyncTransaction interface {
	EntityRepository
	InventoryRepository
	HomeAssistantRepository
	IdempotencyRepository
	ChangeLogRepository
	ConflictRepository
}
