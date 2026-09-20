package syncpostgres

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/momobox/backend/internal/inventory"
	"github.com/momobox/backend/internal/store/inventorypostgres"
	syncdomain "github.com/momobox/backend/internal/sync"
)

const (
	resolveDeviceSQL = `
SELECT id::text, family_id::text, (revoked_at IS NOT NULL OR deleted_at IS NOT NULL)
FROM sync_devices
WHERE id = $1::uuid`

	currentCursorSQL = `SELECT COALESCE(MAX(cursor), 0) FROM change_log WHERE family_id = $1::uuid`

	pullSQL = `
SELECT change_id::text, cursor, operation, entity, entity_id::text, version, payload
FROM change_log
WHERE family_id = $1::uuid
  AND cursor > $2
ORDER BY cursor ASC
LIMIT $3`

	lockIdempotencySQL = `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`

	readIdempotencySQL = `
SELECT response_payload, expires_at
FROM sync_idempotency
WHERE family_id = $1::uuid
  AND device_id = $2::uuid
  AND idempotency_key = $3
FOR UPDATE`

	deleteIdempotencySQL = `
DELETE FROM sync_idempotency
WHERE family_id = $1::uuid AND device_id = $2::uuid AND idempotency_key = $3`

	insertIdempotencySQL = `
INSERT INTO sync_idempotency (
    idempotency_key, family_id, device_id, operation, entity, entity_id,
    status, response_payload, server_cursor, completed_at
) VALUES (
    $3, $1::uuid, $2::uuid, $4, NULLIF($5, ''), NULLIF($6, '')::uuid,
    $7, $8::jsonb, $9, CURRENT_TIMESTAMP
)`

	appendChangeSQL = `
INSERT INTO change_log (
    change_id, family_id, operation, entity, entity_id, version, payload, updated_by_device
) VALUES (
    $1::uuid, $2::uuid, $3, $4, $5::uuid, $6, $7::jsonb, NULLIF($8, '')::uuid
)
RETURNING cursor`

	insertConflictSQL = `
INSERT INTO conflict_records (
    family_id, change_id, device_id, entity, entity_id, reason,
    server_version, server_payload, client_payload, status
) VALUES (
    $1::uuid, NULL, NULLIF($2, '')::uuid, $3, $4::uuid, $5,
    $6, $7::jsonb, $8::jsonb, 'open'
)`
)

// HomeAssistantExecutor is injected by the composition root. It keeps this SQL
// adapter from owning HA credentials or making network calls itself.
type HomeAssistantExecutor interface {
	ExecuteHomeAssistantCommand(context.Context, string, string, syncdomain.SyncChange) (syncdomain.HomeAssistantCommandResult, error)
}

type Option func(*Repository)

func WithHomeAssistantExecutor(executor HomeAssistantExecutor) Option {
	return func(repository *Repository) { repository.ha = executor }
}

// Repository implements the complete sync persistence boundary with
// PostgreSQL. A Repository is safe for concurrent use; transaction-specific
// family and device scope live only on transactionRepository.
type Repository struct {
	db *sql.DB
	ha HomeAssistantExecutor
}

var _ syncdomain.Repository = (*Repository)(nil)

func New(db *sql.DB, options ...Option) *Repository {
	repository := &Repository{db: db}
	for _, option := range options {
		if option != nil {
			option(repository)
		}
	}
	return repository
}

func (r *Repository) ResolveDevice(ctx context.Context, deviceID string) (syncdomain.DeviceScope, error) {
	if r == nil || r.db == nil {
		return syncdomain.DeviceScope{}, errors.New("sync postgres database is not configured")
	}
	var scope syncdomain.DeviceScope
	err := r.db.QueryRowContext(ctx, resolveDeviceSQL, deviceID).Scan(&scope.DeviceID, &scope.FamilyID, &scope.Revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return syncdomain.DeviceScope{}, syncdomain.ErrDeviceNotFound
	}
	if err != nil {
		return syncdomain.DeviceScope{}, fmt.Errorf("resolve sync device: %w", err)
	}
	return scope, nil
}

func (r *Repository) ReadBootstrap(ctx context.Context, familyID string) (syncdomain.BootstrapSnapshot, error) {
	if r == nil || r.db == nil {
		return syncdomain.BootstrapSnapshot{}, errors.New("sync postgres database is not configured")
	}
	var familyRaw []byte
	err := r.db.QueryRowContext(ctx, `
SELECT jsonb_build_object('id', id, 'name', name, 'created_at', created_at, 'updated_at', updated_at)
FROM families
WHERE id = $1::uuid AND deleted_at IS NULL`, familyID).Scan(&familyRaw)
	if errors.Is(err, sql.ErrNoRows) {
		return syncdomain.BootstrapSnapshot{}, syncdomain.ErrNotFound
	}
	if err != nil {
		return syncdomain.BootstrapSnapshot{}, fmt.Errorf("read bootstrap family: %w", err)
	}
	family := make(map[string]any)
	if err := json.Unmarshal(familyRaw, &family); err != nil {
		return syncdomain.BootstrapSnapshot{}, fmt.Errorf("decode bootstrap family: %w", err)
	}

	snapshot := make(map[string]any, len(entitySpecs))
	for _, entity := range bootstrapEntities {
		spec := entitySpecs[entity]
		query := fmt.Sprintf(`SELECT COALESCE(jsonb_agg(to_jsonb(t) - 'family_id' ORDER BY id), '[]'::jsonb) FROM %s AS t WHERE family_id = $1::uuid`, spec.table)
		var raw []byte
		if err := r.db.QueryRowContext(ctx, query, familyID).Scan(&raw); err != nil {
			return syncdomain.BootstrapSnapshot{}, fmt.Errorf("read bootstrap %s: %w", entity, err)
		}
		var records []map[string]any
		if err := json.Unmarshal(raw, &records); err != nil {
			return syncdomain.BootstrapSnapshot{}, fmt.Errorf("decode bootstrap %s: %w", entity, err)
		}
		snapshot[entity] = records
	}
	var cursor int64
	if err := r.db.QueryRowContext(ctx, currentCursorSQL, familyID).Scan(&cursor); err != nil {
		return syncdomain.BootstrapSnapshot{}, fmt.Errorf("read bootstrap cursor: %w", err)
	}
	return syncdomain.BootstrapSnapshot{
		SchemaVersion:       syncdomain.DefaultSchemaVersion,
		SyncProtocolVersion: syncdomain.DefaultSyncProtocolVersion,
		ServerCursor:        cursor,
		MergeRequired:       cursor > 0,
		AvailableModes: []syncdomain.BootstrapMode{
			syncdomain.BootstrapModeJoinAndMerge,
			syncdomain.BootstrapModeCreateNewFamily,
			syncdomain.BootstrapModeKeepLocalOnly,
		},
		Family:   family,
		Snapshot: snapshot,
	}, nil
}

func (r *Repository) ConfirmBootstrap(ctx context.Context, familyID string, request syncdomain.BootstrapConfirmRequest) (syncdomain.BootstrapConfirmation, error) {
	if r == nil || r.db == nil {
		return syncdomain.BootstrapConfirmation{}, errors.New("sync postgres database is not configured")
	}
	result, err := r.db.ExecContext(ctx, `
UPDATE sync_devices
SET last_seen_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
WHERE id = $1::uuid AND family_id = $2::uuid AND revoked_at IS NULL AND deleted_at IS NULL`, request.DeviceID, familyID)
	if err != nil {
		return syncdomain.BootstrapConfirmation{}, fmt.Errorf("confirm bootstrap device: %w", err)
	}
	if affected, err := result.RowsAffected(); err == nil && affected != 1 {
		return syncdomain.BootstrapConfirmation{}, syncdomain.ErrDeviceNotFound
	}
	var cursor int64
	if err := r.db.QueryRowContext(ctx, currentCursorSQL, familyID).Scan(&cursor); err != nil {
		return syncdomain.BootstrapConfirmation{}, fmt.Errorf("read bootstrap confirmation cursor: %w", err)
	}
	return syncdomain.BootstrapConfirmation{Accepted: true, ServerCursor: cursor}, nil
}

func (r *Repository) Pull(ctx context.Context, familyID string, cursor int64, limit int) (syncdomain.PullPage, error) {
	if r == nil || r.db == nil {
		return syncdomain.PullPage{}, errors.New("sync postgres database is not configured")
	}
	rows, err := r.db.QueryContext(ctx, pullSQL, familyID, cursor, limit+1)
	if err != nil {
		return syncdomain.PullPage{}, fmt.Errorf("pull sync changes: %w", err)
	}
	defer rows.Close()
	changes := make([]syncdomain.ChangeLogEntry, 0, limit+1)
	for rows.Next() {
		var entry syncdomain.ChangeLogEntry
		var version sql.NullInt64
		var payloadRaw []byte
		if err := rows.Scan(&entry.ChangeID, &entry.Cursor, &entry.Operation, &entry.Entity, &entry.EntityID, &version, &payloadRaw); err != nil {
			return syncdomain.PullPage{}, fmt.Errorf("scan sync change: %w", err)
		}
		entry.Version = version.Int64
		if err := json.Unmarshal(payloadRaw, &entry.Payload); err != nil {
			return syncdomain.PullPage{}, fmt.Errorf("decode sync change payload: %w", err)
		}
		if command, ok := entry.Payload["_command"].(string); ok {
			entry.Command = command
			delete(entry.Payload, "_command")
		}
		if clientUpdatedAt, ok := entry.Payload["_client_updated_at"].(string); ok {
			entry.ClientUpdatedAt = clientUpdatedAt
			delete(entry.Payload, "_client_updated_at")
		}
		changes = append(changes, entry)
	}
	if err := rows.Err(); err != nil {
		return syncdomain.PullPage{}, fmt.Errorf("iterate sync changes: %w", err)
	}
	hasMore := len(changes) > limit
	if hasMore {
		changes = changes[:limit]
	}
	nextCursor := cursor
	if len(changes) > 0 {
		nextCursor = changes[len(changes)-1].Cursor
	}
	return syncdomain.PullPage{Changes: changes, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (r *Repository) WithTransaction(ctx context.Context, familyID string, fn func(syncdomain.SyncTransaction) error) error {
	if r == nil || r.db == nil {
		return errors.New("sync postgres database is not configured")
	}
	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return fmt.Errorf("begin sync transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	adapter := &transactionRepository{tx: tx, familyID: familyID, ha: r.ha}
	if err := fn(adapter); err != nil {
		_ = tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit sync transaction: %w", err)
	}
	return nil
}

type transactionRepository struct {
	tx        *sql.Tx
	familyID  string
	deviceID  string
	userID    string
	operation syncdomain.Operation
	entity    string
	entityID  string
	ha        HomeAssistantExecutor
}

var _ syncdomain.SyncTransaction = (*transactionRepository)(nil)

func (r *transactionRepository) GetEntity(ctx context.Context, entity, entityID string) (syncdomain.EntityRecord, error) {
	spec, ok := entitySpecs[entity]
	if !ok {
		return syncdomain.EntityRecord{}, syncdomain.ErrNotFound
	}
	query := fmt.Sprintf(`SELECT version, to_jsonb(t) - 'family_id', deleted_at FROM %s AS t WHERE family_id = $1::uuid AND id = $2::uuid`, spec.table)
	var record syncdomain.EntityRecord
	var payloadRaw []byte
	err := r.tx.QueryRowContext(ctx, query, r.familyID, entityID).Scan(&record.Version, &payloadRaw, &record.DeletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return syncdomain.EntityRecord{}, syncdomain.ErrNotFound
	}
	if err != nil {
		return syncdomain.EntityRecord{}, fmt.Errorf("get %s entity: %w", entity, err)
	}
	if err := json.Unmarshal(payloadRaw, &record.Payload); err != nil {
		return syncdomain.EntityRecord{}, fmt.Errorf("decode %s entity: %w", entity, err)
	}
	record.Entity = entity
	record.EntityID = entityID
	return record, nil
}

func (r *transactionRepository) UpsertEntity(ctx context.Context, mutation syncdomain.EntityMutation) (syncdomain.EntityRecord, error) {
	spec, ok := entitySpecs[mutation.Entity]
	if !ok || mutation.Entity == syncdomain.EntityConsumptionRecords {
		return syncdomain.EntityRecord{}, syncdomain.NewBusinessError("UNSUPPORTED_ENTITY", "unsupported sync entity", map[string]any{"entity": mutation.Entity})
	}
	if mutation.Entity == syncdomain.EntityProductBatches && containsProtectedBatchQuantity(mutation.Payload) {
		return syncdomain.EntityRecord{}, syncdomain.NewBusinessError(
			"INVENTORY_COMMAND_REQUIRED",
			"product_batches.quantity can only be changed by an inventory command",
			nil,
		)
	}
	if err := validateRequiredPayload(spec, mutation.Payload, mutation.BaseVersion == 0); err != nil {
		return syncdomain.EntityRecord{}, syncdomain.NewBusinessError("VALIDATION_FAILED", err.Error(), nil)
	}

	if mutation.BaseVersion == 0 {
		if conflict, found, err := r.lookupMutationConflict(ctx, spec, mutation.EntityID, mutation.BaseVersion); err != nil {
			return syncdomain.EntityRecord{}, err
		} else if found {
			return syncdomain.EntityRecord{}, conflict
		}
	}
	query := buildUpdateSQL(spec)
	if mutation.BaseVersion == 0 {
		query = buildInsertSQL(spec)
	}
	payload, err := json.Marshal(mutation.Payload)
	if err != nil {
		return syncdomain.EntityRecord{}, fmt.Errorf("encode %s payload: %w", mutation.Entity, err)
	}
	var record syncdomain.EntityRecord
	var raw []byte
	err = r.tx.QueryRowContext(ctx, query,
		mutation.EntityID, r.familyID, payload, r.deviceID, mutation.BaseVersion, r.userID,
	).Scan(&record.Version, &raw, &record.DeletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return syncdomain.EntityRecord{}, r.classifyMutationFailure(ctx, spec, mutation.EntityID, mutation.BaseVersion)
	}
	if err != nil {
		return syncdomain.EntityRecord{}, fmt.Errorf("upsert %s entity: %w", mutation.Entity, err)
	}
	if err := json.Unmarshal(raw, &record.Payload); err != nil {
		return syncdomain.EntityRecord{}, fmt.Errorf("decode upserted %s entity: %w", mutation.Entity, err)
	}
	record.Entity = mutation.Entity
	record.EntityID = mutation.EntityID
	r.operation = syncdomain.OperationEntityUpsert
	r.entity = mutation.Entity
	r.entityID = mutation.EntityID
	return record, nil
}

func (r *transactionRepository) DeleteEntity(ctx context.Context, mutation syncdomain.EntityMutation) (syncdomain.EntityRecord, error) {
	spec, ok := entitySpecs[mutation.Entity]
	if !ok || mutation.Entity == syncdomain.EntityConsumptionRecords {
		return syncdomain.EntityRecord{}, syncdomain.NewBusinessError("UNSUPPORTED_ENTITY", "unsupported sync entity", map[string]any{"entity": mutation.Entity})
	}
	query := fmt.Sprintf(`
UPDATE %s AS t
SET deleted_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP,
    updated_by_device = NULLIF($3, '')::uuid,
    version = version + 1
WHERE family_id = $1::uuid AND id = $2::uuid AND version = $4
RETURNING version, to_jsonb(t) - 'family_id', deleted_at`, spec.table)
	var record syncdomain.EntityRecord
	var raw []byte
	err := r.tx.QueryRowContext(ctx, query, r.familyID, mutation.EntityID, r.deviceID, mutation.BaseVersion).Scan(&record.Version, &raw, &record.DeletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return syncdomain.EntityRecord{}, r.classifyMutationFailure(ctx, spec, mutation.EntityID, mutation.BaseVersion)
	}
	if err != nil {
		return syncdomain.EntityRecord{}, fmt.Errorf("delete %s entity: %w", mutation.Entity, err)
	}
	if err := json.Unmarshal(raw, &record.Payload); err != nil {
		return syncdomain.EntityRecord{}, fmt.Errorf("decode deleted %s entity: %w", mutation.Entity, err)
	}
	record.Entity = mutation.Entity
	record.EntityID = mutation.EntityID
	r.operation = syncdomain.OperationEntityDelete
	r.entity = mutation.Entity
	r.entityID = mutation.EntityID
	return record, nil
}

func (r *transactionRepository) ExecuteInventoryCommand(ctx context.Context, change syncdomain.SyncChange) (syncdomain.InventoryCommandResult, error) {
	if r.deviceID == "" || r.userID == "" {
		return syncdomain.InventoryCommandResult{}, errors.New("inventory command requires a resolved sync device")
	}
	command, err := inventoryCommand(r.familyID, r.userID, r.deviceID, change)
	if err != nil {
		return syncdomain.InventoryCommandResult{}, err
	}
	service := inventory.NewService(inventorypostgres.BindTransaction(r.tx, true))
	result, err := service.Execute(ctx, command)
	if err != nil {
		return syncdomain.InventoryCommandResult{}, inventoryBusinessError(err)
	}
	if len(result.Allocations) == 0 {
		return syncdomain.InventoryCommandResult{}, errors.New("inventory command returned no allocations")
	}
	entityID := result.Allocations[0].BatchID
	var version int64
	var raw []byte
	err = r.tx.QueryRowContext(ctx, `
SELECT version, to_jsonb(t) - 'family_id'
FROM product_batches AS t
WHERE family_id = $1::uuid AND id = $2::uuid`, r.familyID, entityID).Scan(&version, &raw)
	if err != nil {
		return syncdomain.InventoryCommandResult{}, fmt.Errorf("read inventory command result: %w", err)
	}
	payload := make(map[string]any)
	if err := json.Unmarshal(raw, &payload); err != nil {
		return syncdomain.InventoryCommandResult{}, fmt.Errorf("decode inventory command result: %w", err)
	}
	payload["operation_id"] = result.OperationID
	payload["command"] = result.Command
	payload["allocations"] = result.Allocations
	r.operation = syncdomain.OperationInventoryCommand
	r.entity = syncdomain.EntityProductBatches
	r.entityID = entityID
	return syncdomain.InventoryCommandResult{EntityID: entityID, Version: version, Payload: payload}, nil
}

func (r *transactionRepository) ExecuteHomeAssistantCommand(ctx context.Context, change syncdomain.SyncChange) (syncdomain.HomeAssistantCommandResult, error) {
	if r.deviceID == "" || r.userID == "" {
		return syncdomain.HomeAssistantCommandResult{}, errors.New("Home Assistant command requires a resolved sync device")
	}
	if r.ha == nil {
		return syncdomain.HomeAssistantCommandResult{}, syncdomain.NewBusinessError("HA_NOT_CONFIGURED", "Home Assistant executor is not configured", nil)
	}
	result, err := r.ha.ExecuteHomeAssistantCommand(ctx, r.familyID, r.userID, change)
	if err != nil {
		return syncdomain.HomeAssistantCommandResult{}, err
	}
	r.operation = syncdomain.OperationHomeAssistantCommand
	r.entity = ""
	r.entityID = ""
	return result, nil
}

func (r *transactionRepository) GetIdempotency(ctx context.Context, deviceID, key string) (syncdomain.IdempotencyRecord, bool, error) {
	if _, err := r.tx.ExecContext(ctx, lockIdempotencySQL, r.familyID+":"+deviceID+":"+key); err != nil {
		return syncdomain.IdempotencyRecord{}, false, fmt.Errorf("lock sync idempotency key: %w", err)
	}
	var revoked bool
	err := r.tx.QueryRowContext(ctx, `
SELECT user_id::text, (revoked_at IS NOT NULL OR deleted_at IS NOT NULL)
FROM sync_devices
WHERE id = $1::uuid AND family_id = $2::uuid
FOR UPDATE`, deviceID, r.familyID).Scan(&r.userID, &revoked)
	if errors.Is(err, sql.ErrNoRows) || revoked {
		return syncdomain.IdempotencyRecord{}, false, syncdomain.ErrDeviceNotFound
	}
	if err != nil {
		return syncdomain.IdempotencyRecord{}, false, fmt.Errorf("resolve transaction device: %w", err)
	}
	r.deviceID = deviceID

	var raw []byte
	var expiresAt sql.NullTime
	err = r.tx.QueryRowContext(ctx, readIdempotencySQL, r.familyID, deviceID, key).Scan(&raw, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return syncdomain.IdempotencyRecord{}, false, nil
	}
	if err != nil {
		return syncdomain.IdempotencyRecord{}, false, fmt.Errorf("read sync idempotency record: %w", err)
	}
	if expiresAt.Valid && !expiresAt.Time.After(time.Now().UTC()) {
		if _, err := r.tx.ExecContext(ctx, deleteIdempotencySQL, r.familyID, deviceID, key); err != nil {
			return syncdomain.IdempotencyRecord{}, false, fmt.Errorf("delete expired sync idempotency record: %w", err)
		}
		return syncdomain.IdempotencyRecord{}, false, nil
	}
	var record syncdomain.IdempotencyRecord
	if err := json.Unmarshal(raw, &record); err != nil {
		return syncdomain.IdempotencyRecord{}, false, fmt.Errorf("decode sync idempotency record: %w", err)
	}
	return record, true, nil
}

func (r *transactionRepository) PutIdempotency(ctx context.Context, deviceID, key string, record syncdomain.IdempotencyRecord) error {
	if deviceID != r.deviceID || r.deviceID == "" {
		return errors.New("sync idempotency device is outside transaction scope")
	}
	payload, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("encode sync idempotency record: %w", err)
	}
	status := record.Outcome.Status
	if status == syncdomain.PushStatusReplayed || status == "" {
		status = record.Outcome.OriginalStatus
	}
	if status != syncdomain.PushStatusAccepted && status != syncdomain.PushStatusConflict && status != syncdomain.PushStatusRejected {
		return fmt.Errorf("unsupported stored sync status %q", status)
	}
	operation := r.operation
	if operation == "" {
		// Validation failures happen before a typed repository method is called;
		// the migration requires an operation value, so use the neutral sync
		// envelope value while preserving the exact outcome in response_payload.
		operation = syncdomain.OperationEntityUpsert
	}
	var cursor any
	if record.Outcome.ServerCursor > 0 {
		cursor = record.Outcome.ServerCursor
	}
	_, err = r.tx.ExecContext(ctx, insertIdempotencySQL,
		r.familyID, deviceID, key, operation, r.entity, r.entityID, status, payload, cursor,
	)
	if err != nil {
		return fmt.Errorf("insert sync idempotency record: %w", err)
	}
	return nil
}

func (r *transactionRepository) AppendChange(ctx context.Context, change syncdomain.ChangeLogEntry) (syncdomain.ChangeLogEntry, error) {
	entity := change.Entity
	if entity == "" && change.Operation == syncdomain.OperationInventoryCommand {
		entity = syncdomain.EntityProductBatches
	}
	if entity == "" || change.EntityID == "" {
		return syncdomain.ChangeLogEntry{}, errors.New("change log requires entity and entity_id")
	}
	payload := copyMap(change.Payload)
	if change.Command != "" {
		payload["_command"] = change.Command
	}
	if change.ClientUpdatedAt != "" {
		payload["_client_updated_at"] = change.ClientUpdatedAt
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return syncdomain.ChangeLogEntry{}, fmt.Errorf("encode change log payload: %w", err)
	}
	var version any
	if change.Version > 0 {
		version = change.Version
	}
	err = r.tx.QueryRowContext(ctx, appendChangeSQL,
		change.ChangeID, r.familyID, change.Operation, entity, change.EntityID,
		version, raw, r.deviceID,
	).Scan(&change.Cursor)
	if err != nil {
		return syncdomain.ChangeLogEntry{}, fmt.Errorf("append sync change: %w", err)
	}
	change.Entity = entity
	return change, nil
}

func (r *transactionRepository) CurrentCursor(ctx context.Context) (int64, error) {
	var cursor int64
	if err := r.tx.QueryRowContext(ctx, currentCursorSQL, r.familyID).Scan(&cursor); err != nil {
		return 0, fmt.Errorf("read current sync cursor: %w", err)
	}
	return cursor, nil
}

func (r *transactionRepository) RecordConflict(ctx context.Context, conflict syncdomain.SyncConflict) error {
	serverMap := conflict.ServerPayload
	if serverMap == nil {
		serverMap = map[string]any{}
	}
	serverPayload, err := json.Marshal(serverMap)
	if err != nil {
		return fmt.Errorf("encode conflict server payload: %w", err)
	}
	clientPayload := copyMap(conflict.ClientPayload)
	clientPayload["_change_id"] = conflict.ChangeID
	clientRaw, err := json.Marshal(clientPayload)
	if err != nil {
		return fmt.Errorf("encode conflict client payload: %w", err)
	}
	var serverVersion any
	if conflict.ServerVersion > 0 {
		serverVersion = conflict.ServerVersion
	}
	_, err = r.tx.ExecContext(ctx, insertConflictSQL,
		r.familyID, r.deviceID, conflict.Entity, conflict.EntityID, conflict.Reason,
		serverVersion, serverPayload, clientRaw,
	)
	if err != nil {
		return fmt.Errorf("record sync conflict: %w", err)
	}
	return nil
}

func (r *transactionRepository) classifyMutationFailure(ctx context.Context, spec entitySpec, entityID string, baseVersion int64) error {
	conflict, found, err := r.lookupMutationConflict(ctx, spec, entityID, baseVersion)
	if err != nil {
		return err
	}
	if found {
		return conflict
	}
	return syncdomain.NewBusinessError("VERSION_CONFLICT", "entity does not exist at the requested version", map[string]any{"server_version": int64(0)})
}

func (r *transactionRepository) lookupMutationConflict(ctx context.Context, spec entitySpec, entityID string, baseVersion int64) (error, bool, error) {
	query := fmt.Sprintf(`SELECT family_id::text, version, to_jsonb(t) - 'family_id' FROM %s AS t WHERE id = $1::uuid`, spec.table)
	var familyID string
	var version int64
	var raw []byte
	err := r.tx.QueryRowContext(ctx, query, entityID).Scan(&familyID, &version, &raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("classify entity mutation failure: %w", err)
	}
	if familyID != r.familyID {
		return syncdomain.NewBusinessError("FAMILY_SCOPE_VIOLATION", "entity belongs to another family", nil), true, nil
	}
	payload := make(map[string]any)
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, false, fmt.Errorf("decode conflicting entity: %w", err)
	}
	return syncdomain.NewBusinessError("VERSION_CONFLICT", "entity version changed", map[string]any{
		"server_version": version,
		"base_version":   baseVersion,
		"server_payload": payload,
	}), true, nil
}

func inventoryCommand(familyID, actorID, deviceID string, change syncdomain.SyncChange) (inventory.Command, error) {
	command := inventory.Command{
		FamilyID:       familyID,
		ActorID:        actorID,
		DeviceID:       deviceID,
		OperationID:    firstNonEmpty(change.OperationID, change.ChangeID),
		IdempotencyKey: change.IdempotencyKey,
		Command:        inventory.CommandName(change.Command),
	}
	allocations := change.Allocations
	if len(allocations) == 0 {
		allocations = allocationsFromPayload(change.Payload)
	}
	switch command.Command {
	case inventory.CommandConsumeFEFO:
		command.ProductID = stringValue(change.Payload, "product_id")
		if command.ProductID == "" {
			command.ProductID = change.EntityID
		}
		command.Quantity = intValue(change.Payload, "quantity")
	case inventory.CommandConsumeAllocated:
		for _, allocation := range allocations {
			command.Allocations = append(command.Allocations, inventory.Allocation{BatchID: allocation.BatchID, Quantity: int(allocation.Quantity)})
		}
	case inventory.CommandRestock, inventory.CommandDiscard:
		if len(allocations) != 1 {
			return inventory.Command{}, syncdomain.NewBusinessError("VALIDATION_FAILED", "restock and discard require exactly one batch allocation", nil)
		}
		command.BatchID = allocations[0].BatchID
		command.Quantity = int(allocations[0].Quantity)
	default:
		return inventory.Command{}, syncdomain.NewBusinessError("UNSUPPORTED_INVENTORY_COMMAND", "unsupported inventory command", nil)
	}
	return command, nil
}

func inventoryBusinessError(err error) error {
	switch {
	case errors.Is(err, inventory.ErrInvalidCommand):
		return syncdomain.NewBusinessError("VALIDATION_FAILED", err.Error(), nil)
	case errors.Is(err, inventory.ErrInsufficientStock):
		return syncdomain.NewBusinessError("INSUFFICIENT_STOCK", err.Error(), nil)
	case errors.Is(err, inventory.ErrBatchUnavailable):
		return syncdomain.NewBusinessError("BATCH_UNAVAILABLE", err.Error(), nil)
	default:
		return err
	}
}

func allocationsFromPayload(payload map[string]any) []syncdomain.InventoryAllocation {
	raw, ok := payload["allocations"]
	if !ok {
		return nil
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		return nil
	}
	var allocations []syncdomain.InventoryAllocation
	if json.Unmarshal(encoded, &allocations) != nil {
		return nil
	}
	return allocations
}

func stringValue(payload map[string]any, key string) string {
	value, _ := payload[key].(string)
	return strings.TrimSpace(value)
}

func intValue(payload map[string]any, key string) int {
	switch value := payload[key].(type) {
	case int:
		return value
	case int64:
		return int(value)
	case float64:
		return int(value)
	case json.Number:
		parsed, _ := strconv.Atoi(value.String())
		return parsed
	default:
		return 0
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func copyMap(source map[string]any) map[string]any {
	result := make(map[string]any, len(source)+2)
	for key, value := range source {
		result[key] = value
	}
	return result
}
