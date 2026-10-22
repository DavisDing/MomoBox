package sync

import "testing"

func TestOrdinaryBatchUpdatesRequireStrictCalendarDates(t *testing.T) {
	for _, value := range []any{"2026-10-22T00:00:00Z", "10/22/2026", "2026-02-30", "0000-01-01", 1792627200} {
		change := SyncChange{Entity: EntityProductBatches, Payload: map[string]any{"expiry_date": value}}
		if err := validateEntityPayload(change); err == nil {
			t.Errorf("ordinary update accepted noncalendar value %#v", value)
		}
	}
	for _, value := range []any{nil, "2026-10-22", "2028-02-29"} {
		change := SyncChange{Entity: EntityProductBatches, Payload: map[string]any{"expiry_date": value}}
		if err := validateEntityPayload(change); err != nil {
			t.Errorf("ordinary update rejected calendar value %#v: %v", value, err)
		}
	}
}
