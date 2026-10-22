package family

import (
	"testing"
	"time"
)

func TestFamilyCalendarDayUsesFamilyZoneAcrossMidnightAndDST(t *testing.T) {
	for _, test := range []struct{ instant, zone, want string }{
		{"2026-10-22T16:30:00Z", "Asia/Shanghai", "2026-10-23"},
		{"2026-10-22T01:30:00Z", "America/Los_Angeles", "2026-10-21"},
		{"2026-03-08T09:59:59Z", "America/Los_Angeles", "2026-03-08"},
		{"2026-03-08T10:00:00Z", "America/Los_Angeles", "2026-03-08"},
		{"2026-10-22T16:30:00Z", "", "2026-10-23"},
	} {
		instant, err := time.Parse(time.RFC3339, test.instant)
		if err != nil {
			t.Fatal(err)
		}
		day, err := CalendarDay(instant, test.zone)
		if err != nil || day.Format("2006-01-02") != test.want {
			t.Fatalf("%s in %s = %v, %v", test.instant, test.zone, day, err)
		}
	}
}
