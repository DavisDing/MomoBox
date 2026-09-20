package inventorypostgres

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/momobox/backend/internal/inventory"
)

const (
	findBatchesForUpdateSQL = `
SELECT id::text, family_id::text, product_id::text, expiry_date, quantity, status
FROM product_batches
WHERE family_id = $1::uuid
  AND product_id = $2::uuid
  AND deleted_at IS NULL
ORDER BY expiry_date ASC NULLS LAST, id ASC
FOR UPDATE`

	findBatchForUpdateSQL = `
SELECT id::text, family_id::text, product_id::text, expiry_date, quantity, status
FROM product_batches
WHERE family_id = $1::uuid
  AND id = $2::uuid
  AND deleted_at IS NULL
FOR UPDATE`

	applyBatchChangeSQL = `
UPDATE product_batches
SET quantity = quantity + $3,
    status = CASE
        WHEN $4::text = 'discarded' THEN 'discarded'
        WHEN quantity + $3 = 0 THEN 'used_up'
        ELSE 'active'
    END,
    version = version + 1,
    updated_at = CURRENT_TIMESTAMP
WHERE family_id = $1::uuid
  AND id = $2::uuid
  AND deleted_at IS NULL
  AND quantity + $3 >= 0
RETURNING product_id::text`

	lockIdempotencySQL = `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`

	findIdempotencySQL = `
SELECT status, response_payload, expires_at
FROM sync_idempotency
WHERE family_id = $1::uuid
  AND device_id = $2::uuid
  AND idempotency_key = $3
FOR UPDATE`

	deleteIdempotencySQL = `
DELETE FROM sync_idempotency
WHERE family_id = $1::uuid
  AND device_id = $2::uuid
  AND idempotency_key = $3`

	saveIdempotencySQL = `
INSERT INTO sync_idempotency (
    idempotency_key, family_id, device_id, operation, entity, status,
    response_payload, completed_at
) VALUES ($3, $1::uuid, $2::uuid, 'inventory_command', 'product_batches',
          'accepted', $4::jsonb, CURRENT_TIMESTAMP)
ON CONFLICT (family_id, device_id, idempotency_key) DO NOTHING`

	appendConsumptionSQL = `
INSERT INTO consumption_records (
    family_id, batch_id, product_id, record_type, quantity_change, reason,
    operation_id, idempotency_key, created_by_user_id, device_id, created_at
) VALUES (
    $1::uuid, $2::uuid, $3::uuid, $4, $5, $6,
    $7::uuid, $8, $9::uuid, $10::uuid, $11
)`

	appendInventoryChangeSQL = `
INSERT INTO change_log (
    change_id, family_id, operation, entity, entity_id, payload, updated_by_device
) VALUES (
    $1::uuid, $2::uuid, 'inventory_command', 'product_batches', $3::uuid,
    $4::jsonb, $5::uuid
)
RETURNING cursor`
)

// Repository is a PostgreSQL implementation of inventory.Store. Every command
// runs in one SQL transaction and every mutable batch must first be selected
// with FOR UPDATE under the command's family_id.
type Repository struct {
	db *sql.DB
}

var _ inventory.Store = (*Repository)(nil)

func New(db *sql.DB) *Repository {
	return &Repository{db: db}
}

func (r *Repository) RunInTransaction(ctx context.Context, fn func(context.Context, inventory.Tx) error) error {
	if r == nil || r.db == nil {
		return errors.New("inventory postgres database is not configured")
	}
	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return fmt.Errorf("begin inventory transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	adapter := newTx(tx, false)
	if err := fn(ctx, adapter); err != nil {
		_ = tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit inventory transaction: %w", err)
	}
	return nil
}

// BoundStore lets a caller that already owns a SQL transaction execute the
// inventory service without nesting transactions. skipIdempotency is intended
// for the sync repository, whose outer transaction owns the idempotency record.
type BoundStore struct {
	tx              *sql.Tx
	skipIdempotency bool
}

var _ inventory.Store = (*BoundStore)(nil)

func BindTransaction(tx *sql.Tx, skipIdempotency bool) *BoundStore {
	return &BoundStore{tx: tx, skipIdempotency: skipIdempotency}
}

func (s *BoundStore) RunInTransaction(ctx context.Context, fn func(context.Context, inventory.Tx) error) error {
	if s == nil || s.tx == nil {
		return errors.New("inventory postgres transaction is not configured")
	}
	return fn(ctx, newTx(s.tx, s.skipIdempotency))
}

type txRepository struct {
	tx              *sql.Tx
	skipIdempotency bool
	locked          map[string]lockedBatch
	familyID        string
	deviceID        string
	actorID         string
}

type lockedBatch struct {
	FamilyID  string
	ProductID string
}

var _ inventory.Tx = (*txRepository)(nil)

func newTx(tx *sql.Tx, skipIdempotency bool) *txRepository {
	return &txRepository{tx: tx, skipIdempotency: skipIdempotency, locked: make(map[string]lockedBatch)}
}

func (r *txRepository) FindBatchesForUpdate(ctx context.Context, familyID, productID string) ([]inventory.Batch, error) {
	if err := r.bindFamily(familyID); err != nil {
		return nil, err
	}
	rows, err := r.tx.QueryContext(ctx, findBatchesForUpdateSQL, familyID, productID)
	if err != nil {
		return nil, fmt.Errorf("lock product batches: %w", err)
	}
	defer rows.Close()

	batches := make([]inventory.Batch, 0)
	for rows.Next() {
		var batch inventory.Batch
		var status string
		if err := rows.Scan(&batch.ID, &batch.FamilyID, &batch.ProductID, &batch.ExpiresOn, &batch.Quantity, &status); err != nil {
			return nil, fmt.Errorf("scan product batch: %w", err)
		}
		batch.Status = domainBatchStatus(status)
		r.locked[batch.ID] = lockedBatch{FamilyID: batch.FamilyID, ProductID: batch.ProductID}
		batches = append(batches, batch)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate product batches: %w", err)
	}
	return batches, nil
}

func (r *txRepository) FindBatchForUpdate(ctx context.Context, familyID, batchID string) (inventory.Batch, error) {
	if err := r.bindFamily(familyID); err != nil {
		return inventory.Batch{}, err
	}
	var batch inventory.Batch
	var status string
	err := r.tx.QueryRowContext(ctx, findBatchForUpdateSQL, familyID, batchID).Scan(
		&batch.ID, &batch.FamilyID, &batch.ProductID, &batch.ExpiresOn, &batch.Quantity, &status,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return inventory.Batch{}, inventory.ErrBatchUnavailable
	}
	if err != nil {
		return inventory.Batch{}, fmt.Errorf("lock product batch: %w", err)
	}
	batch.Status = domainBatchStatus(status)
	r.locked[batch.ID] = lockedBatch{FamilyID: batch.FamilyID, ProductID: batch.ProductID}
	return batch, nil
}

func (r *txRepository) FindIdempotentResult(ctx context.Context, familyID, deviceID, key string) (inventory.Result, bool, error) {
	if r.skipIdempotency {
		return inventory.Result{}, false, nil
	}
	if err := r.bindFamily(familyID); err != nil {
		return inventory.Result{}, false, err
	}
	r.deviceID = deviceID
	if _, err := r.tx.ExecContext(ctx, lockIdempotencySQL, familyID+":"+deviceID+":"+key); err != nil {
		return inventory.Result{}, false, fmt.Errorf("lock inventory idempotency key: %w", err)
	}
	var status string
	var raw []byte
	var expiresAt sql.NullTime
	err := r.tx.QueryRowContext(ctx, findIdempotencySQL, familyID, deviceID, key).Scan(&status, &raw, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return inventory.Result{}, false, nil
	}
	if err != nil {
		return inventory.Result{}, false, fmt.Errorf("read inventory idempotency result: %w", err)
	}
	if expiresAt.Valid && !expiresAt.Time.After(time.Now().UTC()) {
		if _, err := r.tx.ExecContext(ctx, deleteIdempotencySQL, familyID, deviceID, key); err != nil {
			return inventory.Result{}, false, fmt.Errorf("delete expired inventory idempotency result: %w", err)
		}
		return inventory.Result{}, false, nil
	}
	if status != "accepted" {
		return inventory.Result{}, false, fmt.Errorf("inventory idempotency key already has status %q", status)
	}
	var envelope struct {
		InventoryResult inventory.Result `json:"inventory_result"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return inventory.Result{}, false, fmt.Errorf("decode inventory idempotency result: %w", err)
	}
	if strings.TrimSpace(envelope.InventoryResult.OperationID) == "" {
		return inventory.Result{}, false, errors.New("inventory idempotency payload is incompatible")
	}
	return envelope.InventoryResult, true, nil
}

func (r *txRepository) SaveIdempotentResult(ctx context.Context, familyID, deviceID, key string, result inventory.Result) error {
	if r.skipIdempotency {
		return nil
	}
	if err := r.bindFamily(familyID); err != nil {
		return err
	}
	if strings.TrimSpace(r.deviceID) == "" || deviceID != r.deviceID {
		return errors.New("inventory idempotency device is outside transaction scope")
	}
	payload, err := json.Marshal(map[string]any{"inventory_result": result})
	if err != nil {
		return fmt.Errorf("encode inventory idempotency result: %w", err)
	}
	res, err := r.tx.ExecContext(ctx, saveIdempotencySQL, familyID, deviceID, key, payload)
	if err != nil {
		return fmt.Errorf("save inventory idempotency result: %w", err)
	}
	if affected, err := res.RowsAffected(); err == nil && affected != 1 {
		return errors.New("inventory idempotency result already exists")
	}
	return nil
}

func (r *txRepository) ApplyBatchChanges(ctx context.Context, changes []inventory.BatchChange) error {
	for _, change := range changes {
		locked, ok := r.locked[change.BatchID]
		if !ok || locked.FamilyID == "" || locked.FamilyID != r.familyID {
			return fmt.Errorf("batch %s was not locked for this family", change.BatchID)
		}
		status := ""
		if change.NewStatus != nil {
			status = string(*change.NewStatus)
		}
		var productID string
		err := r.tx.QueryRowContext(ctx, applyBatchChangeSQL, locked.FamilyID, change.BatchID, change.QuantityDelta, status).Scan(&productID)
		if errors.Is(err, sql.ErrNoRows) {
			return inventory.ErrInsufficientStock
		}
		if err != nil {
			return fmt.Errorf("apply product batch change: %w", err)
		}
		r.locked[change.BatchID] = lockedBatch{FamilyID: locked.FamilyID, ProductID: productID}
	}
	return nil
}

func (r *txRepository) AppendConsumptionRecord(ctx context.Context, record inventory.ConsumptionRecord) error {
	locked, ok := r.locked[record.BatchID]
	if !ok || locked.FamilyID != record.FamilyID || record.FamilyID != r.familyID {
		return errors.New("consumption record batch is outside the locked family scope")
	}
	recordType, quantityDelta, err := consumptionValues(record.Command, record.Quantity)
	if err != nil {
		return err
	}
	_, err = r.tx.ExecContext(ctx, appendConsumptionSQL,
		record.FamilyID, record.BatchID, locked.ProductID, recordType, quantityDelta,
		string(record.Command), record.OperationID, consumptionIdempotencyKey(record.OperationID, record.BatchID),
		record.ActorID, record.DeviceID, record.OccurredAt,
	)
	if err != nil {
		return fmt.Errorf("append consumption record: %w", err)
	}
	r.actorID = record.ActorID
	r.deviceID = record.DeviceID
	return nil
}

func (r *txRepository) AppendChange(ctx context.Context, familyID string, result inventory.Result) error {
	if r.skipIdempotency {
		// The outer sync transaction appends the canonical change_log entry.
		return nil
	}
	if err := r.bindFamily(familyID); err != nil {
		return err
	}
	if len(result.Allocations) == 0 {
		return errors.New("inventory result has no allocations")
	}
	payload, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encode inventory change: %w", err)
	}
	_, err = r.tx.ExecContext(ctx, appendInventoryChangeSQL,
		result.OperationID, familyID, result.Allocations[0].BatchID, payload, r.deviceID,
	)
	if err != nil {
		return fmt.Errorf("append inventory change: %w", err)
	}
	return nil
}

func (r *txRepository) bindFamily(familyID string) error {
	familyID = strings.TrimSpace(familyID)
	if familyID == "" {
		return errors.New("family_id is required")
	}
	if r.familyID != "" && r.familyID != familyID {
		return errors.New("inventory transaction cannot cross family scope")
	}
	r.familyID = familyID
	return nil
}

func domainBatchStatus(status string) inventory.BatchStatus {
	if status == "active" || status == "used_up" {
		return inventory.BatchAvailable
	}
	return inventory.BatchDiscarded
}

func consumptionValues(command inventory.CommandName, quantity int) (string, int, error) {
	switch command {
	case inventory.CommandConsumeFEFO, inventory.CommandConsumeAllocated:
		return "consume", -quantity, nil
	case inventory.CommandRestock:
		return "restock", quantity, nil
	case inventory.CommandDiscard:
		return "discard", -quantity, nil
	default:
		return "", 0, inventory.ErrInvalidCommand
	}
}

func consumptionIdempotencyKey(operationID, batchID string) string {
	sum := sha256.Sum256([]byte(operationID + "\x00" + batchID))
	return "inventory-record:" + hex.EncodeToString(sum[:])
}
