package inventory_test

import (
	"context"
	"testing"
	"time"

	"github.com/momobox/backend/internal/inventory"
)

type fakeStore struct {
	batches   []inventory.Batch
	result    inventory.Result
	hasResult bool
	changes   []inventory.BatchChange
	records   []inventory.ConsumptionRecord
}
type fakeTx struct{ s *fakeStore }

func (s *fakeStore) RunInTransaction(ctx context.Context, fn func(context.Context, inventory.Tx) error) error {
	return fn(ctx, &fakeTx{s: s})
}
func (t *fakeTx) FindBatchesForUpdate(_ context.Context, family, product string) ([]inventory.Batch, error) {
	var out []inventory.Batch
	for _, b := range t.s.batches {
		if b.FamilyID == family && b.ProductID == product {
			out = append(out, b)
		}
	}
	return out, nil
}
func (t *fakeTx) FindBatchForUpdate(_ context.Context, family, id string) (inventory.Batch, error) {
	for _, b := range t.s.batches {
		if b.FamilyID == family && b.ID == id {
			return b, nil
		}
	}
	return inventory.Batch{}, inventory.ErrBatchUnavailable
}
func (t *fakeTx) FindIdempotentResult(context.Context, string, string, string) (inventory.Result, bool, error) {
	return t.s.result, t.s.hasResult, nil
}
func (t *fakeTx) SaveIdempotentResult(context.Context, string, string, string, inventory.Result) error {
	t.s.result = inventory.Result{}
	t.s.hasResult = true
	return nil
}
func (t *fakeTx) ApplyBatchChanges(_ context.Context, changes []inventory.BatchChange) error {
	t.s.changes = append(t.s.changes, changes...)
	return nil
}
func (t *fakeTx) AppendConsumptionRecord(_ context.Context, r inventory.ConsumptionRecord) error {
	t.s.records = append(t.s.records, r)
	return nil
}
func (t *fakeTx) AppendChange(context.Context, string, inventory.Result) error { return nil }

func TestConsumeFEFOUsesExpiryAndSkipsExpired(t *testing.T) {
	today := time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC)
	tomorrow := today.AddDate(0, 0, 1)
	yesterday := today.AddDate(0, 0, -1)
	s := &fakeStore{batches: []inventory.Batch{{ID: "late", FamilyID: "f", ProductID: "p", ExpiresOn: &tomorrow, Quantity: 3, Status: inventory.BatchAvailable}, {ID: "expired", FamilyID: "f", ProductID: "p", ExpiresOn: &yesterday, Quantity: 5, Status: inventory.BatchAvailable}, {ID: "none", FamilyID: "f", ProductID: "p", Quantity: 4, Status: inventory.BatchAvailable}}}
	service := inventory.NewServiceWithClock(s, func() time.Time { return today })
	got, err := service.Execute(context.Background(), inventory.Command{FamilyID: "f", ActorID: "u", DeviceID: "d", OperationID: "o", IdempotencyKey: "k", ProductID: "p", Quantity: 2, Command: inventory.CommandConsumeFEFO})
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Allocations) != 1 || got.Allocations[0].BatchID != "late" || got.Allocations[0].Quantity != 2 {
		t.Fatalf("unexpected allocations: %#v", got.Allocations)
	}
}

func TestReplayDoesNotWriteAgain(t *testing.T) {
	s := &fakeStore{hasResult: true, result: inventory.Result{OperationID: "o", Command: inventory.CommandRestock}}
	got, err := inventory.NewService(s).Execute(context.Background(), inventory.Command{FamilyID: "f", ActorID: "u", DeviceID: "d", OperationID: "o", IdempotencyKey: "k", BatchID: "b", Quantity: 1, Command: inventory.CommandRestock})
	if err != nil {
		t.Fatal(err)
	}
	if !got.Replayed {
		t.Fatal("expected replay")
	}
	if len(s.changes) != 0 || len(s.records) != 0 {
		t.Fatal("replay wrote changes")
	}
}
