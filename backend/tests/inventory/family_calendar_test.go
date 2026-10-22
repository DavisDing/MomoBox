package inventory_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/momobox/backend/internal/inventory"
)

type calendarStore struct {
	fakeStore
	zone string
}

type calendarTx struct {
	fakeTx
	zone string
}

func (s *calendarStore) RunInTransaction(ctx context.Context, fn func(context.Context, inventory.Tx) error) error {
	return fn(ctx, &calendarTx{fakeTx: fakeTx{s: &s.fakeStore}, zone: s.zone})
}

func (tx *calendarTx) FamilyTimeZone(context.Context, string) (string, error) {
	return tx.zone, nil
}

func TestConsumptionExpiryUsesFamilyDateAndKeepsExpiryDayAvailable(t *testing.T) {
	expiry := time.Date(2026, 10, 22, 0, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		name, zone, instant string
		expired             bool
	}{
		{"Shanghai expiry day", "Asia/Shanghai", "2026-10-22T15:59:59Z", false},
		{"Shanghai next day", "Asia/Shanghai", "2026-10-22T16:00:00Z", true},
		{"Los Angeles still expiry day", "America/Los_Angeles", "2026-10-23T06:59:59Z", false},
		{"Los Angeles next day", "America/Los_Angeles", "2026-10-23T07:00:00Z", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			for _, command := range []inventory.CommandName{inventory.CommandConsumeFEFO, inventory.CommandConsumeAllocated} {
				store := &calendarStore{
					fakeStore: fakeStore{batches: []inventory.Batch{{
						ID: "b", FamilyID: "f", ProductID: "p", ExpiresOn: &expiry,
						Quantity: 1, Status: inventory.BatchAvailable,
					}}},
					zone: test.zone,
				}
				now, err := time.Parse(time.RFC3339, test.instant)
				if err != nil {
					t.Fatal(err)
				}
				request := inventory.Command{
					FamilyID: "f", ActorID: "u", DeviceID: "d", OperationID: "o",
					IdempotencyKey: "k", ProductID: "p", Quantity: 1, Command: command,
					Allocations: []inventory.Allocation{{BatchID: "b", Quantity: 1}},
				}
				_, err = inventory.NewServiceWithClock(store, func() time.Time { return now }).Execute(context.Background(), request)
				if test.expired {
					if !errors.Is(err, inventory.ErrInsufficientStock) && !errors.Is(err, inventory.ErrBatchUnavailable) {
						t.Fatalf("expired allocation error = %v", err)
					}
					if len(store.changes) != 0 {
						t.Fatal("expired stock changed")
					}
				} else if err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
