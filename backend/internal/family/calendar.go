package family

import (
	"fmt"
	"time"
	_ "time/tzdata" // IANA rules remain available in minimal runtime images.
)

const DefaultTimeZone = "Asia/Shanghai"

// CalendarDay preserves a date's written year/month/day. It never converts an
// expiry DATE through UTC; only event instants are converted to the family zone.
func CalendarDay(instant time.Time, zone string) (time.Time, error) {
	if zone == "" {
		zone = DefaultTimeZone
	}
	if zone == "Local" {
		return time.Time{}, fmt.Errorf("an explicit IANA family time zone is required")
	}
	location, err := time.LoadLocation(zone)
	if err != nil {
		return time.Time{}, err
	}
	local := instant.In(location)
	return time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC), nil
}
