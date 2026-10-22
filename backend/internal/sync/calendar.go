package sync

import "time"

func validCalendarDate(value any) bool {
	text, ok := value.(string)
	if !ok {
		return false
	}
	date, err := time.Parse("2006-01-02", text)
	return err == nil && date.Year() >= 1 && date.Format("2006-01-02") == text
}

// ValidateCalendarDates applies to both ordinary entity updates and imports.
// A timestamp is never coerced into a calendar day by PostgreSQL's DATE cast.
func ValidateCalendarDates(payload map[string]any) error {
	for _, field := range []string{"produced_date", "expiry_date", "opened_date"} {
		value := payload[field]
		if value != nil && !validCalendarDate(value) {
			return NewBusinessError("VALIDATION_FAILED", field+" must be a valid YYYY-MM-DD calendar date", nil)
		}
	}
	return nil
}
