package inventory

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

var (
	ErrInvalidCommand    = errors.New("invalid inventory command")
	ErrInsufficientStock = errors.New("insufficient stock")
	ErrBatchUnavailable  = errors.New("batch unavailable")
)

type CommandName string

const (
	CommandConsumeFEFO      CommandName = "consume_fefo"
	CommandConsumeAllocated CommandName = "consume_allocated"
	CommandRestock          CommandName = "restock"
	CommandDiscard          CommandName = "discard"
)

type BatchStatus string

const (
	BatchAvailable BatchStatus = "available"
	BatchDiscarded BatchStatus = "discarded"
)

type Command struct {
	FamilyID       string
	ActorID        string
	DeviceID       string
	OperationID    string
	IdempotencyKey string
	ProductID      string
	BatchID        string
	Quantity       int
	Command        CommandName
	Allocations    []Allocation
}

type Allocation struct {
	BatchID  string
	Quantity int
}

type Batch struct {
	ID        string
	FamilyID  string
	ProductID string
	ExpiresOn *time.Time
	Quantity  int
	Status    BatchStatus
}

type BatchChange struct {
	BatchID       string
	QuantityDelta int
	NewStatus     *BatchStatus
}

type ConsumptionRecord struct {
	ID          string
	FamilyID    string
	ActorID     string
	DeviceID    string
	OperationID string
	Command     CommandName
	BatchID     string
	Quantity    int
	OccurredAt  time.Time
}

type Result struct {
	OperationID string
	Command     CommandName
	Allocations []Allocation
	Replayed    bool
}

// Store is the transaction boundary required by the inventory service. The
// implementation must lock affected batches until Commit returns.
type Store interface {
	RunInTransaction(ctx context.Context, fn func(context.Context, Tx) error) error
}

type Tx interface {
	FindBatchesForUpdate(ctx context.Context, familyID, productID string) ([]Batch, error)
	FindBatchForUpdate(ctx context.Context, familyID, batchID string) (Batch, error)
	FindIdempotentResult(ctx context.Context, familyID, deviceID, key string) (Result, bool, error)
	SaveIdempotentResult(ctx context.Context, familyID, deviceID, key string, result Result) error
	ApplyBatchChanges(ctx context.Context, changes []BatchChange) error
	AppendConsumptionRecord(ctx context.Context, record ConsumptionRecord) error
	AppendChange(ctx context.Context, familyID string, result Result) error
}

type Service struct {
	store Store
	now   func() time.Time
}

func NewService(store Store) *Service {
	return NewServiceWithClock(store, func() time.Time { return time.Now().UTC() })
}

// NewServiceWithClock keeps time-sensitive FEFO and expiry decisions deterministic
// in tests and lets callers share one server clock without trusting client time.
func NewServiceWithClock(store Store, now func() time.Time) *Service {
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}
	return &Service{store: store, now: now}
}

func (s *Service) Execute(ctx context.Context, command Command) (Result, error) {
	if err := validateCommand(command); err != nil {
		return Result{}, err
	}
	var result Result
	err := s.store.RunInTransaction(ctx, func(txCtx context.Context, tx Tx) error {
		if replay, ok, err := tx.FindIdempotentResult(txCtx, command.FamilyID, command.DeviceID, command.IdempotencyKey); err != nil {
			return err
		} else if ok {
			replay.Replayed = true
			result = replay
			return nil
		}

		allocations, err := s.plan(txCtx, tx, command)
		if err != nil {
			return err
		}
		changes := make([]BatchChange, 0, len(allocations))
		for _, allocation := range allocations {
			changes = append(changes, BatchChange{BatchID: allocation.BatchID, QuantityDelta: quantityDelta(command.Command, allocation.Quantity)})
		}
		if command.Command == CommandDiscard {
			status := BatchDiscarded
			for i := range changes {
				changes[i].NewStatus = &status
			}
		}
		if err := tx.ApplyBatchChanges(txCtx, changes); err != nil {
			return err
		}
		occurredAt := s.now().UTC()
		for _, allocation := range allocations {
			if err := tx.AppendConsumptionRecord(txCtx, ConsumptionRecord{
				ID: newOperationRecordID(command.OperationID, allocation.BatchID), FamilyID: command.FamilyID,
				ActorID: command.ActorID, DeviceID: command.DeviceID, OperationID: command.OperationID,
				Command: command.Command, BatchID: allocation.BatchID, Quantity: allocation.Quantity, OccurredAt: occurredAt,
			}); err != nil {
				return err
			}
		}
		result = Result{OperationID: command.OperationID, Command: command.Command, Allocations: allocations}
		if err := tx.AppendChange(txCtx, command.FamilyID, result); err != nil {
			return err
		}
		return tx.SaveIdempotentResult(txCtx, command.FamilyID, command.DeviceID, command.IdempotencyKey, result)
	})
	return result, err
}

func (s *Service) plan(ctx context.Context, tx Tx, command Command) ([]Allocation, error) {
	switch command.Command {
	case CommandConsumeFEFO:
		batches, err := tx.FindBatchesForUpdate(ctx, command.FamilyID, command.ProductID)
		if err != nil {
			return nil, err
		}
		return allocateFEFO(batches, command.Quantity, s.now())
	case CommandConsumeAllocated:
		return validateAllocated(ctx, tx, command, s.now())
	case CommandRestock, CommandDiscard:
		batch, err := tx.FindBatchForUpdate(ctx, command.FamilyID, command.BatchID)
		if err != nil {
			return nil, err
		}
		if batch.Status == BatchDiscarded || batch.Quantity < 0 {
			return nil, ErrBatchUnavailable
		}
		if command.Command == CommandDiscard && command.Quantity > batch.Quantity {
			return nil, ErrInsufficientStock
		}
		return []Allocation{{BatchID: batch.ID, Quantity: command.Quantity}}, nil
	default:
		return nil, ErrInvalidCommand
	}
}

func allocateFEFO(batches []Batch, quantity int, now time.Time) ([]Allocation, error) {
	if quantity < 1 {
		return nil, ErrInvalidCommand
	}
	today := dateOnly(now)
	candidates := make([]Batch, 0, len(batches))
	available := 0
	for _, batch := range batches {
		if batch.Status == BatchDiscarded || batch.Quantity <= 0 {
			continue
		}
		if batch.ExpiresOn != nil && dateOnly(*batch.ExpiresOn).Before(today) {
			continue
		}
		available += batch.Quantity
		candidates = append(candidates, batch)
	}
	if available < quantity {
		return nil, ErrInsufficientStock
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		left, right := candidates[i].ExpiresOn, candidates[j].ExpiresOn
		if left == nil && right != nil {
			return false
		}
		if left != nil && right == nil {
			return true
		}
		if left != nil && right != nil {
			if dateOnly(*left) != dateOnly(*right) {
				return dateOnly(*left).Before(dateOnly(*right))
			}
		}
		return candidates[i].ID < candidates[j].ID
	})
	remaining := quantity
	allocations := make([]Allocation, 0, len(candidates))
	for _, batch := range candidates {
		amount := batch.Quantity
		if amount > remaining {
			amount = remaining
		}
		allocations = append(allocations, Allocation{BatchID: batch.ID, Quantity: amount})
		remaining -= amount
		if remaining == 0 {
			break
		}
	}
	return allocations, nil
}

func validateAllocated(ctx context.Context, tx Tx, command Command, now time.Time) ([]Allocation, error) {
	if len(command.Allocations) == 0 {
		return nil, ErrInvalidCommand
	}
	seen := map[string]struct{}{}
	out := make([]Allocation, 0, len(command.Allocations))
	for _, allocation := range command.Allocations {
		if allocation.BatchID == "" || allocation.Quantity < 1 {
			return nil, ErrInvalidCommand
		}
		if _, ok := seen[allocation.BatchID]; ok {
			return nil, ErrInvalidCommand
		}
		seen[allocation.BatchID] = struct{}{}
		batch, err := tx.FindBatchForUpdate(ctx, command.FamilyID, allocation.BatchID)
		if err != nil {
			return nil, err
		}
		if batch.Status == BatchDiscarded || batch.Quantity < allocation.Quantity {
			return nil, ErrInsufficientStock
		}
		if batch.ExpiresOn != nil && dateOnly(*batch.ExpiresOn).Before(dateOnly(now)) {
			return nil, ErrBatchUnavailable
		}
		out = append(out, allocation)
	}
	return out, nil
}

func validateCommand(command Command) error {
	for name, value := range map[string]string{"family_id": command.FamilyID, "actor_id": command.ActorID, "device_id": command.DeviceID, "operation_id": command.OperationID, "idempotency_key": command.IdempotencyKey} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%w: %s is required", ErrInvalidCommand, name)
		}
	}
	switch command.Command {
	case CommandConsumeFEFO:
		if strings.TrimSpace(command.ProductID) == "" || command.Quantity < 1 {
			return ErrInvalidCommand
		}
	case CommandConsumeAllocated:
		if len(command.Allocations) == 0 {
			return ErrInvalidCommand
		}
	case CommandRestock, CommandDiscard:
		if strings.TrimSpace(command.BatchID) == "" || command.Quantity < 1 {
			return ErrInvalidCommand
		}
	default:
		return ErrInvalidCommand
	}
	return nil
}

func quantityDelta(command CommandName, quantity int) int {
	if command == CommandRestock {
		return quantity
	}
	return -quantity
}

func dateOnly(value time.Time) time.Time {
	value = value.UTC()
	return time.Date(value.Year(), value.Month(), value.Day(), 0, 0, 0, 0, time.UTC)
}

func newOperationRecordID(operationID, batchID string) string { return operationID + ":" + batchID }
