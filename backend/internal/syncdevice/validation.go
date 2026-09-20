package syncdevice

import (
	"strings"
	"time"
)

const (
	maxDeviceNameLength = 120
	maxAppVersionLength = 64
)

func validateActor(actor Actor) error {
	if strings.TrimSpace(actor.UserID) == "" || strings.TrimSpace(actor.FamilyID) == "" {
		return ErrUnauthorized
	}
	switch actor.Role {
	case RoleOwner, RoleAdmin, RoleMember:
		return nil
	default:
		return ErrUnauthorized
	}
}

func validateRegisterRequest(request RegisterDeviceRequest) error {
	if err := validateUUID(request.DeviceID, "device_id"); err != nil {
		return err
	}
	if err := validateText(request.DeviceName, "device_name", maxDeviceNameLength); err != nil {
		return err
	}
	switch request.Platform {
	case PlatformAndroid, PlatformIOS, PlatformOther:
	default:
		return &ValidationError{Field: "platform", Reason: "must be android, ios, or other"}
	}
	if len([]rune(request.AppVersion)) > maxAppVersionLength {
		return &ValidationError{Field: "app_version", Reason: "is too long"}
	}
	return nil
}

func validateText(value, field string, maxLength int) error {
	if strings.TrimSpace(value) == "" {
		return &ValidationError{Field: field, Reason: "is required"}
	}
	if len([]rune(value)) > maxLength {
		return &ValidationError{Field: field, Reason: "is too long"}
	}
	return nil
}

func validateUUID(value, field string) error {
	if len(value) != 36 {
		return &ValidationError{Field: field, Reason: "must be a UUID"}
	}
	for index, character := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if character != '-' {
				return &ValidationError{Field: field, Reason: "must be a UUID"}
			}
			continue
		}
		if !isHex(character) {
			return &ValidationError{Field: field, Reason: "must be a UUID"}
		}
	}
	return nil
}

func isHex(value rune) bool {
	return value >= '0' && value <= '9' || value >= 'a' && value <= 'f' || value >= 'A' && value <= 'F'
}

func validateDeviceID(value string) error { return validateUUID(value, "device_id") }

func validateCursor(cursor int64) error {
	if cursor < 0 {
		return &ValidationError{Field: "cursor", Reason: "must be greater than or equal to zero"}
	}
	return nil
}

func normalizeNow(now time.Time) time.Time {
	if now.IsZero() {
		return time.Now().UTC()
	}
	return now.UTC()
}
