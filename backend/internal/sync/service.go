package sync

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const (
	DefaultSchemaVersion       = 1
	DefaultSyncProtocolVersion = 1
	DefaultPullLimit           = 100
	MaxPullLimit               = 500
	MaxPushChanges             = 100
)

const (
	EntityProducts           = "products"
	EntityProductBatches     = "product_batches"
	EntityConsumptionRecords = "consumption_records"
	EntityShoppingItems      = "shopping_items"
	EntityCategories         = "categories"
	EntityReminderSettings   = "reminder_settings"
)

const (
	InventoryCommandConsumeFEFO      = "consume_fefo"
	InventoryCommandConsumeAllocated = "consume_allocated"
	InventoryCommandRestock          = "restock"
	InventoryCommandDiscard          = "discard"
)

// Service implements the sync contract without depending on an HTTP router or
// a concrete database. A repository transaction must provide the locking and
// commit guarantees described by docs/nas/01-domain-sync-model.md.
type Service struct {
	repository Repository
}

// SyncService is an explicit alias for callers that prefer the domain name.
type SyncService = Service

func NewService(repository Repository) *Service {
	return &Service{repository: repository}
}

func NewSyncService(repository Repository) *Service {
	return NewService(repository)
}

func (s *Service) Bootstrap(ctx context.Context, request BootstrapRequest) (BootstrapResponse, error) {
	if err := validateDeviceID(request.DeviceID); err != nil {
		return BootstrapResponse{}, err
	}
	scope, err := s.repository.ResolveDevice(ctx, request.DeviceID)
	if err != nil {
		return BootstrapResponse{}, err
	}
	if scope.Revoked {
		return BootstrapResponse{}, ErrDeviceNotFound
	}
	var snapshot BootstrapSnapshot
	if deviceRepository, ok := s.repository.(DeviceBootstrapRepository); ok {
		snapshot, err = deviceRepository.ReadBootstrapForDevice(ctx, scope.FamilyID, scope.DeviceID)
	} else {
		snapshot, err = s.repository.ReadBootstrap(ctx, scope.FamilyID)
	}
	if err != nil {
		return BootstrapResponse{}, err
	}
	modes := append([]BootstrapMode(nil), snapshot.AvailableModes...)
	if len(modes) == 0 {
		modes = []BootstrapMode{BootstrapModeJoinAndMerge, BootstrapModeCreateNewFamily, BootstrapModeKeepLocalOnly}
	}
	return BootstrapResponse{
		SchemaVersion:       valueOrDefault(snapshot.SchemaVersion, DefaultSchemaVersion),
		SyncProtocolVersion: valueOrDefault(snapshot.SyncProtocolVersion, DefaultSyncProtocolVersion),
		ServerCursor:        snapshot.ServerCursor,
		MergeRequired:       snapshot.MergeRequired,
		BootstrapState:      snapshot.BootstrapState,
		Checkpoint:          snapshot.Checkpoint,
		AvailableModes:      modes,
		Family:              cloneMap(snapshot.Family),
		Snapshot:            cloneMap(snapshot.Snapshot),
	}, nil
}

func (s *Service) ConfirmBootstrap(ctx context.Context, request BootstrapConfirmRequest) (BootstrapConfirmResponse, error) {
	if err := validateBootstrapConfirm(request); err != nil {
		return BootstrapConfirmResponse{}, err
	}
	scope, err := s.repository.ResolveDevice(ctx, request.DeviceID)
	if err != nil {
		return BootstrapConfirmResponse{}, err
	}
	if scope.Revoked {
		return BootstrapConfirmResponse{}, ErrDeviceNotFound
	}
	confirmation, err := s.repository.ConfirmBootstrap(ctx, scope.FamilyID, request)
	if err != nil {
		return BootstrapConfirmResponse{}, err
	}
	return BootstrapConfirmResponse{
		Accepted:       confirmation.Accepted,
		NextAction:     bootstrapNextAction(request.Mode),
		ServerCursor:   confirmation.ServerCursor,
		Checkpoint:     confirmation.Checkpoint,
		BootstrapState: confirmation.BootstrapState,
	}, nil
}

func (s *Service) ListConflicts(ctx context.Context, request ConflictListRequest) (ConflictListResponse, error) {
	if err := validateDeviceID(request.DeviceID); err != nil { return ConflictListResponse{}, err }
	scope, err := s.repository.ResolveDevice(ctx, request.DeviceID)
	if err != nil { return ConflictListResponse{}, err }
	if scope.Revoked { return ConflictListResponse{}, ErrDeviceNotFound }
	query, ok := s.repository.(ConflictQueryRepository)
	if !ok { return ConflictListResponse{}, errors.New("sync conflict repository is not configured") }
	request.Limit = minConflictLimit(request.Limit)
	if request.Status != "" && request.Status != ConflictStatusOpen && request.Status != ConflictStatusResolved && request.Status != ConflictStatusRejected { return ConflictListResponse{}, fmt.Errorf("%w: unsupported conflict status", ErrInvalidRequest) }
	if scoped, ok := s.repository.(ScopedConflictQueryRepository); ok {
		return scoped.ListConflictsForScope(ctx, request, scope)
	}
	return query.ListConflicts(ctx, request)
}

func (s *Service) GetConflict(ctx context.Context, deviceID, conflictID string) (SyncConflict, error) {
	if err := validateDeviceID(deviceID); err != nil { return SyncConflict{}, err }
	if strings.TrimSpace(conflictID) == "" { return SyncConflict{}, fmt.Errorf("%w: conflict_id is required", ErrInvalidRequest) }
	scope, err := s.repository.ResolveDevice(ctx, deviceID); if err != nil { return SyncConflict{}, err }
	if scope.Revoked { return SyncConflict{}, ErrDeviceNotFound }
	query, ok := s.repository.(ConflictQueryRepository); if !ok { return SyncConflict{}, errors.New("sync conflict repository is not configured") }
	if scoped, ok := s.repository.(ScopedConflictQueryRepository); ok {
		return scoped.GetConflictForScope(ctx, conflictID, scope)
	}
	return query.GetConflict(ctx, conflictID)
}

func (s *Service) ResolveConflict(ctx context.Context, request ConflictResolveRequest) (ConflictResolveResponse, error) {
	if err := validateConflictResolve(request); err != nil { return ConflictResolveResponse{}, err }
	scope, err := s.repository.ResolveDevice(ctx, request.DeviceID); if err != nil { return ConflictResolveResponse{}, err }
	if scope.Revoked { return ConflictResolveResponse{}, ErrDeviceNotFound }
	if !canResolveConflict(scope.Role) { return ConflictResolveResponse{}, NewBusinessError("FORBIDDEN", "only family owner or admin can resolve sync conflicts", nil) }
	query, ok := s.repository.(ConflictQueryRepository); if !ok { return ConflictResolveResponse{}, errors.New("sync conflict repository is not configured") }
	return query.ResolveConflict(ctx, request, scope)
}

func (s *Service) Pull(ctx context.Context, request PullRequest) (PullResponse, error) {
	if err := validatePullRequest(request); err != nil {
		return PullResponse{}, err
	}
	scope, err := s.repository.ResolveDevice(ctx, request.DeviceID)
	if err != nil {
		return PullResponse{}, err
	}
	if scope.Revoked {
		return PullResponse{}, ErrDeviceNotFound
	}
	limit := request.Limit
	if limit == 0 {
		limit = DefaultPullLimit
	}
	page, err := s.repository.Pull(ctx, scope.FamilyID, request.Cursor, limit)
	if err != nil {
		return PullResponse{}, err
	}
	if page.NextCursor < request.Cursor {
		return PullResponse{}, fmt.Errorf("%w: pull next_cursor moved backwards", ErrInvalidRequest)
	}
	return PullResponse{
		Changes:    cloneChanges(page.Changes),
		NextCursor: page.NextCursor,
		HasMore:    page.HasMore,
	}, nil
}

func (s *Service) Push(ctx context.Context, request PushRequest) (PushResponse, error) {
	if err := validatePushRequest(request); err != nil {
		return PushResponse{}, err
	}
	scope, err := s.repository.ResolveDevice(ctx, request.DeviceID)
	if err != nil {
		return PushResponse{}, err
	}
	if scope.Revoked {
		return PushResponse{}, ErrDeviceNotFound
	}

	response := PushResponse{
		Accepted:  make([]AcceptedChange, 0, len(request.Changes)),
		Replayed:  make([]ReplayedChange, 0),
		Conflicts: make([]SyncConflict, 0),
		Rejected:  make([]RejectedChange, 0),
		Results:   make([]PushResult, 0, len(request.Changes)),
		Cursor:    request.BaseCursor,
	}
	for _, change := range request.Changes {
		outcome, err := s.processChange(ctx, scope, request.BaseCursor, change)
		if err != nil {
			return PushResponse{}, err
		}
		appendOutcome(&response, outcome, change.ChangeID)
		if outcome.ServerCursor > response.Cursor {
			response.Cursor = outcome.ServerCursor
		}
	}
	return response, nil
}

func (s *Service) processChange(ctx context.Context, scope DeviceScope, baseCursor int64, change SyncChange) (StoredOutcome, error) {
	fingerprint, err := fingerprint(scope.DeviceID, change)
	if err != nil {
		return StoredOutcome{}, err
	}
	var outcome StoredOutcome
	err = s.repository.WithTransaction(ctx, scope.FamilyID, func(tx SyncTransaction) error {
		record, found, err := tx.GetIdempotency(ctx, scope.DeviceID, change.IdempotencyKey)
		if err != nil {
			return err
		}
		currentCursor, err := tx.CurrentCursor(ctx)
		if err != nil {
			return err
		}
		if found {
			if record.Fingerprint != fingerprint {
				outcome = rejectedOutcome(change, "IDEMPOTENCY_KEY_REUSE", "幂等键已用于不同请求", nil, baseCursor)
				return nil
			}
			outcome = cloneOutcome(record.Outcome)
			outcome.OriginalStatus = outcome.Status
			outcome.Status = PushStatusReplayed
			outcome.ServerCursor = currentCursor
			return nil
		}

		if baseCursor > currentCursor {
			outcome = rejectedOutcome(change, "INVALID_CURSOR", "客户端 cursor 超过服务端当前 cursor", map[string]any{"server_cursor": currentCursor}, currentCursor)
			return tx.PutIdempotency(ctx, scope.DeviceID, change.IdempotencyKey, IdempotencyRecord{Fingerprint: fingerprint, Outcome: outcome})
		}

		if err := validateChange(change); err != nil {
			outcome = rejectedOutcome(change, "VALIDATION_FAILED", err.Error(), nil, currentCursor)
			return tx.PutIdempotency(ctx, scope.DeviceID, change.IdempotencyKey, IdempotencyRecord{Fingerprint: fingerprint, Outcome: outcome})
		}

		outcome, err = s.applyChange(ctx, tx, change, currentCursor)
		if err != nil {
			return err
		}
		return tx.PutIdempotency(ctx, scope.DeviceID, change.IdempotencyKey, IdempotencyRecord{Fingerprint: fingerprint, Outcome: outcome})
	})
	if err != nil {
		return StoredOutcome{}, err
	}
	return outcome, nil
}

func (s *Service) applyChange(ctx context.Context, tx SyncTransaction, change SyncChange, baseCursor int64) (StoredOutcome, error) {
	switch change.Operation {
	case OperationEntityUpsert, OperationEntityDelete:
		return s.applyEntityChange(ctx, tx, change, baseCursor)
	case OperationInventoryCommand:
		return s.applyInventoryChange(ctx, tx, change, baseCursor)
	case OperationHomeAssistantCommand:
		return s.applyHomeAssistantChange(ctx, tx, change, baseCursor)
	default:
		return rejectedOutcome(change, "UNSUPPORTED_OPERATION", "不支持的同步操作", nil, baseCursor), nil
	}
}

func (s *Service) applyEntityChange(ctx context.Context, tx SyncTransaction, change SyncChange, baseCursor int64) (StoredOutcome, error) {
	current, err := tx.GetEntity(ctx, change.Entity, change.EntityID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return StoredOutcome{}, err
	}
	if errors.Is(err, ErrNotFound) {
		current = EntityRecord{Entity: change.Entity, EntityID: change.EntityID}
	}
	if change.BaseVersion != current.Version {
		conflict := SyncConflict{
			ChangeID:      change.ChangeID,
			Operation:     change.Operation,
			Entity:        change.Entity,
			EntityID:      change.EntityID,
			Reason:        "VERSION_CONFLICT",
			ServerVersion: current.Version,
			ServerPayload: cloneMap(current.Payload),
			ClientPayload: conflictClientPayload(change),
		}
		if err := recordConflict(ctx, tx, &conflict); err != nil {
			return StoredOutcome{}, err
		}
		return StoredOutcome{Status: PushStatusConflict, Conflict: &conflict, ServerCursor: baseCursor}, nil
	}

	mutation := EntityMutation{
		Operation:       change.Operation,
		Entity:          change.Entity,
		EntityID:        change.EntityID,
		BaseVersion:     change.BaseVersion,
		Payload:         cloneMap(change.Payload),
		ClientUpdatedAt: change.ClientUpdatedAt,
		ChangeID:        change.ChangeID,
	}
	var updated EntityRecord
	if change.Operation == OperationEntityUpsert {
		updated, err = tx.UpsertEntity(ctx, mutation)
	} else {
		updated, err = tx.DeleteEntity(ctx, mutation)
	}
	if err != nil {
		return s.businessOutcomeOrError(ctx, tx, change, err, baseCursor)
	}
	entry := ChangeLogEntry{
		ChangeID:        change.ChangeID,
		Operation:       change.Operation,
		Entity:          change.Entity,
		EntityID:        change.EntityID,
		Version:         updated.Version,
		Payload:         cloneMap(updated.Payload),
		ClientUpdatedAt: change.ClientUpdatedAt,
	}
	appended, err := tx.AppendChange(ctx, entry)
	if err != nil {
		return StoredOutcome{}, err
	}
	return StoredOutcome{
		Status: PushStatusAccepted,
		Accepted: &AcceptedChange{
			ChangeID:      change.ChangeID,
			EntityID:      change.EntityID,
			ServerVersion: updated.Version,
			ServerCursor:  appended.Cursor,
			Result:        cloneMap(updated.Payload),
			Status:        PushStatusAccepted,
		},
		ServerCursor: appended.Cursor,
	}, nil
}

func (s *Service) applyInventoryChange(ctx context.Context, tx SyncTransaction, change SyncChange, baseCursor int64) (StoredOutcome, error) {
	result, err := tx.ExecuteInventoryCommand(ctx, change)
	if err != nil {
		return s.businessOutcomeOrError(ctx, tx, change, err, baseCursor)
	}
	entry := ChangeLogEntry{
		ChangeID:        change.ChangeID,
		Operation:       change.Operation,
		Entity:          change.Entity,
		EntityID:        result.EntityID,
		Version:         result.Version,
		Payload:         cloneMap(result.Payload),
		Command:         change.Command,
		ClientUpdatedAt: change.ClientUpdatedAt,
	}
	appended, err := tx.AppendChange(ctx, entry)
	if err != nil {
		return StoredOutcome{}, err
	}
	return StoredOutcome{
		Status: PushStatusAccepted,
		Accepted: &AcceptedChange{
			ChangeID:      change.ChangeID,
			EntityID:      result.EntityID,
			ServerVersion: result.Version,
			ServerCursor:  appended.Cursor,
			Result:        cloneMap(result.Payload),
			Status:        PushStatusAccepted,
		},
		ServerCursor: appended.Cursor,
	}, nil
}

func (s *Service) applyHomeAssistantChange(ctx context.Context, tx SyncTransaction, change SyncChange, baseCursor int64) (StoredOutcome, error) {
	result, err := tx.ExecuteHomeAssistantCommand(ctx, change)
	if err != nil {
		return s.businessOutcomeOrError(ctx, tx, change, err, baseCursor)
	}
	cursor, err := tx.CurrentCursor(ctx)
	if err != nil {
		return StoredOutcome{}, err
	}
	return StoredOutcome{
		Status: PushStatusAccepted,
		Accepted: &AcceptedChange{
			ChangeID:     change.ChangeID,
			ServerCursor: cursor,
			Result:       cloneMap(result.Payload),
			Status:       PushStatusAccepted,
		},
		ServerCursor: cursor,
	}, nil
}

func conflictClientPayload(change SyncChange) map[string]any {
	payload := cloneMap(change.Payload)
	if payload == nil {
		payload = map[string]any{}
	}
	payload["base_version"] = change.BaseVersion
	return payload
}

func recordConflict(ctx context.Context, tx SyncTransaction, conflict *SyncConflict) error {
	if writer, ok := tx.(ConflictRecordRepository); ok {
		return writer.RecordConflictWithID(ctx, conflict)
	}
	return tx.RecordConflict(ctx, *conflict)
}

func (s *Service) businessOutcomeOrError(ctx context.Context, tx SyncTransaction, change SyncChange, err error, cursor int64) (StoredOutcome, error) {
	code, message, details, ok := businessCode(err)
	if !ok {
		return StoredOutcome{}, err
	}
	if code == "VERSION_CONFLICT" || code == "FAMILY_SCOPE_VIOLATION" {
		conflict := SyncConflict{
			ChangeID:      change.ChangeID,
			Operation:     change.Operation,
			Entity:        change.Entity,
			EntityID:      change.EntityID,
			Reason:        code,
			ClientPayload: conflictClientPayload(change),
		}
		if details != nil {
			if value, ok := details["server_version"].(int64); ok {
				conflict.ServerVersion = value
			}
			if payload, ok := details["server_payload"].(map[string]any); ok {
				conflict.ServerPayload = cloneMap(payload)
			}
		}
		if recordErr := recordConflict(ctx, tx, &conflict); recordErr != nil {
			return StoredOutcome{}, recordErr
		}
		return StoredOutcome{Status: PushStatusConflict, Conflict: &conflict, ServerCursor: cursor}, nil
	}
	rejected := rejectedOutcome(change, code, message, details, cursor)
	return rejected, nil
}

func appendOutcome(response *PushResponse, outcome StoredOutcome, changeID string) {
	result := PushResult{ChangeID: changeID, Status: outcome.Status}
	switch outcome.Status {
	case PushStatusAccepted:
		if outcome.Accepted != nil {
			accepted := *outcome.Accepted
			accepted.Result = cloneMap(accepted.Result)
			response.Accepted = append(response.Accepted, accepted)
			result.Accepted = &accepted
		}
	case PushStatusConflict:
		if outcome.Conflict != nil {
			conflict := cloneConflict(*outcome.Conflict)
			response.Conflicts = append(response.Conflicts, conflict)
			result.Conflict = &conflict
		}
	case PushStatusRejected:
		if outcome.Rejected != nil {
			rejected := cloneRejected(*outcome.Rejected)
			response.Rejected = append(response.Rejected, rejected)
			result.Rejected = &rejected
		}
	case PushStatusReplayed:
		originalStatus := outcome.OriginalStatus
		if originalStatus == "" {
			originalStatus = inferOutcomeStatus(outcome)
		}
		replayed := ReplayedChange{
			ChangeID:       changeID,
			OriginalStatus: originalStatus,
			Accepted:       cloneAccepted(outcome.Accepted),
			Rejected:       cloneRejectedPtr(outcome.Rejected),
		}
		if outcome.Conflict != nil {
			conflict := cloneConflict(*outcome.Conflict)
			replayed.Conflict = &conflict
		}
		response.Replayed = append(response.Replayed, replayed)
		result.OriginalStatus = originalStatus
		result.Accepted = cloneAccepted(outcome.Accepted)
		result.Rejected = cloneRejectedPtr(outcome.Rejected)
		if outcome.Conflict != nil {
			conflict := cloneConflict(*outcome.Conflict)
			result.Conflict = &conflict
		}
	}
	response.Results = append(response.Results, result)
}

func inferOutcomeStatus(outcome StoredOutcome) PushStatus {
	if outcome.Accepted != nil {
		return PushStatusAccepted
	}
	if outcome.Conflict != nil {
		return PushStatusConflict
	}
	return PushStatusRejected
}

func cloneRejectedPtr(value *RejectedChange) *RejectedChange {
	if value == nil {
		return nil
	}
	copyValue := cloneRejected(*value)
	return &copyValue
}

func rejectedOutcome(change SyncChange, code, message string, details map[string]any, cursor int64) StoredOutcome {
	rejected := &RejectedChange{ChangeID: change.ChangeID, Code: code, Message: message, Details: cloneMap(details)}
	return StoredOutcome{Status: PushStatusRejected, Rejected: rejected, ServerCursor: cursor}
}

func bootstrapNextAction(mode BootstrapMode) string {
	switch mode {
	case BootstrapModeJoinAndMerge:
		return "pull_snapshot"
	case BootstrapModeCreateNewFamily:
		return "push_local_changes"
	default:
		return "keep_local_only"
	}
}

func validateDeviceID(value string) error {
	if strings.TrimSpace(value) == "" {
		return fmt.Errorf("%w: device_id is required", ErrInvalidRequest)
	}
	return nil
}

func validatePushRequest(request PushRequest) error {
	if err := validateDeviceID(request.DeviceID); err != nil {
		return err
	}
	if request.BaseCursor < 0 {
		return fmt.Errorf("%w: base_cursor must be non-negative", ErrInvalidRequest)
	}
	if len(request.Changes) == 0 {
		return fmt.Errorf("%w: changes must not be empty", ErrInvalidRequest)
	}
	if len(request.Changes) > MaxPushChanges {
		return fmt.Errorf("%w: changes exceeds %d", ErrInvalidRequest, MaxPushChanges)
	}
	return nil
}

func validatePullRequest(request PullRequest) error {
	if err := validateDeviceID(request.DeviceID); err != nil {
		return err
	}
	if request.Cursor < 0 {
		return fmt.Errorf("%w: cursor must be non-negative", ErrInvalidRequest)
	}
	if request.Limit < 0 || request.Limit > MaxPullLimit {
		return fmt.Errorf("%w: limit must be between 1 and %d", ErrInvalidRequest, MaxPullLimit)
	}
	return nil
}

func validateConflictResolve(request ConflictResolveRequest) error {
	if err := validateDeviceID(request.DeviceID); err != nil { return err }
	if strings.TrimSpace(request.ConflictID) == "" { return fmt.Errorf("%w: conflict_id is required", ErrInvalidRequest) }
	switch request.Action { case ConflictActionKeepLocal, ConflictActionKeepRemote, ConflictActionManualMerge, ConflictActionDefer: default: return fmt.Errorf("%w: unsupported conflict action", ErrInvalidRequest) }
	if request.ExpectedVersion < 0 { return fmt.Errorf("%w: expected_version must be non-negative", ErrInvalidRequest) }
	if request.Action == ConflictActionManualMerge && request.MergedPayload == nil { return fmt.Errorf("%w: merged_payload is required", ErrInvalidRequest) }
	if request.IdempotencyKey != "" && (len(request.IdempotencyKey) < 16 || len(request.IdempotencyKey) > 255) { return fmt.Errorf("%w: idempotency_key must contain 16 to 255 characters", ErrInvalidRequest) }
	return nil
}

func canResolveConflict(role string) bool {
	role = strings.ToLower(strings.TrimSpace(role))
	return role == "owner" || role == "admin"
}

func minConflictLimit(value int) int { if value <= 0 { return 50 }; if value > 200 { return 200 }; return value }

func validateBootstrapConfirm(request BootstrapConfirmRequest) error {
	if err := validateDeviceID(request.DeviceID); err != nil {
		return err
	}
	switch request.Mode {
	case BootstrapModeJoinAndMerge, BootstrapModeCreateNewFamily, BootstrapModeKeepLocalOnly:
		return nil
	default:
		return fmt.Errorf("%w: unsupported bootstrap mode", ErrInvalidRequest)
	}
}

func validateChange(change SyncChange) error {
	if strings.TrimSpace(change.ChangeID) == "" {
		return fmt.Errorf("change_id is required")
	}
	if len(change.IdempotencyKey) < 16 || len(change.IdempotencyKey) > 255 {
		return fmt.Errorf("idempotency_key must contain 16 to 255 characters")
	}
	if change.BaseVersion < 0 {
		return fmt.Errorf("base_version must be non-negative")
	}
	if change.ClientUpdatedAt != "" {
		if _, err := time.Parse(time.RFC3339, change.ClientUpdatedAt); err != nil {
			return fmt.Errorf("client_updated_at must be RFC3339")
		}
	}
	switch change.Operation {
	case OperationEntityUpsert:
		if err := validateEntityIdentity(change); err != nil {
			return err
		}
		return validateEntityPayload(change)
	case OperationEntityDelete:
		if err := validateEntityIdentity(change); err != nil {
			return err
		}
		if change.Entity == EntityConsumptionRecords {
			return fmt.Errorf("consumption_records must be changed by inventory_command")
		}
		return nil
	case OperationInventoryCommand:
		return validateInventoryCommand(change)
	case OperationHomeAssistantCommand:
		if strings.TrimSpace(change.IntegrationID) == "" || strings.TrimSpace(change.EntityID) == "" || strings.TrimSpace(change.Command) == "" {
			return fmt.Errorf("home_assistant_command requires integration_id, entity_id and command")
		}
		return nil
	default:
		return fmt.Errorf("unsupported operation %q", change.Operation)
	}
}

func validateEntityIdentity(change SyncChange) error {
	if strings.TrimSpace(change.Entity) == "" || strings.TrimSpace(change.EntityID) == "" {
		return fmt.Errorf("entity and entity_id are required")
	}
	return nil
}

func validateEntityPayload(change SyncChange) error {
	if change.Entity == EntityProductBatches {
		for _, field := range []string{"quantity", "current_quantity", "quantity_change"} {
			if _, exists := change.Payload[field]; exists {
				return fmt.Errorf("product_batches.%s must be changed by inventory_command", field)
			}
		}
	}
	if change.Entity == EntityConsumptionRecords {
		return fmt.Errorf("consumption_records must be created by inventory_command")
	}
	return nil
}

func validateInventoryCommand(change SyncChange) error {
	if strings.TrimSpace(change.Command) == "" {
		return fmt.Errorf("inventory command is required")
	}
	switch change.Command {
	case InventoryCommandConsumeFEFO, InventoryCommandConsumeAllocated, InventoryCommandRestock, InventoryCommandDiscard:
	default:
		return fmt.Errorf("unsupported inventory command %q", change.Command)
	}
	allocations := change.Allocations
	if len(allocations) == 0 && change.Payload != nil {
		if raw, ok := change.Payload["allocations"]; ok {
			encoded, err := json.Marshal(raw)
			if err != nil {
				return fmt.Errorf("invalid allocations")
			}
			if err := json.Unmarshal(encoded, &allocations); err != nil {
				return fmt.Errorf("invalid allocations")
			}
		}
	}
	if change.Command == InventoryCommandConsumeAllocated || change.Command == InventoryCommandRestock || change.Command == InventoryCommandDiscard {
		if len(allocations) == 0 {
			return fmt.Errorf("%s requires allocations", change.Command)
		}
		for _, allocation := range allocations {
			if strings.TrimSpace(allocation.BatchID) == "" || allocation.Quantity <= 0 {
				return fmt.Errorf("allocations require a batch_id and positive quantity")
			}
		}
	}
	return nil
}

func fingerprint(deviceID string, change SyncChange) (string, error) {
	canonical := struct {
		DeviceID string     `json:"device_id"`
		Change   SyncChange `json:"change"`
	}{deviceID, change}
	encoded, err := json.Marshal(canonical)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(encoded)
	return hex.EncodeToString(hash[:]), nil
}

func cloneOutcome(value StoredOutcome) StoredOutcome {
	value.Accepted = cloneAccepted(value.Accepted)
	if value.Conflict != nil {
		conflict := cloneConflict(*value.Conflict)
		value.Conflict = &conflict
	}
	if value.Rejected != nil {
		rejected := cloneRejected(*value.Rejected)
		value.Rejected = &rejected
	}
	return value
}

func cloneAccepted(value *AcceptedChange) *AcceptedChange {
	if value == nil {
		return nil
	}
	copyValue := *value
	copyValue.Result = cloneMap(value.Result)
	return &copyValue
}

func cloneConflict(value SyncConflict) SyncConflict {
	value.ServerPayload = cloneMap(value.ServerPayload)
	value.ClientPayload = cloneMap(value.ClientPayload)
	return value
}

func cloneRejected(value RejectedChange) RejectedChange {
	value.Details = cloneMap(value.Details)
	return value
}

func cloneChanges(values []ChangeLogEntry) []ChangeLogEntry {
	if values == nil {
		return nil
	}
	result := make([]ChangeLogEntry, len(values))
	for index, value := range values {
		result[index] = value
		result[index].Payload = cloneMap(value.Payload)
	}
	return result
}

func cloneMap(value map[string]any) map[string]any {
	if value == nil {
		return nil
	}
	result := make(map[string]any, len(value))
	for key, item := range value {
		result[key] = item
	}
	return result
}

func valueOrDefault(value, fallback int) int {
	if value == 0 {
		return fallback
	}
	return value
}
