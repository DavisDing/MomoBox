package syncdevice

import "time"

// Platform is the client platform recorded for a sync device.
type Platform string

const (
	PlatformAndroid Platform = "android"
	PlatformIOS     Platform = "ios"
	PlatformOther   Platform = "other"
)

// DeviceStatus is derived from RevokedAt. A revoked device can never be
// reactivated by a heartbeat or cursor update.
type DeviceStatus string

const (
	DeviceStatusActive  DeviceStatus = "active"
	DeviceStatusRevoked DeviceStatus = "revoked"
)

// Role is the family role used by the device-management authorization boundary.
type Role string

const (
	RoleOwner  Role = "owner"
	RoleAdmin  Role = "admin"
	RoleMember Role = "member"
)

// Actor is the authenticated request principal supplied by the auth layer.
// This package does not parse or validate access tokens.
type Actor struct {
	UserID   string
	FamilyID string
	Role     Role
	// DeviceID is the device identity in the authenticated token. It is needed
	// for Current, TouchCurrent, and RecordCurrentSync.
	DeviceID string
}

// Device is the persistence-facing sync device entity. It intentionally has
// no Home Assistant fields: HA devices belong to a different state domain.
type Device struct {
	ID             string
	UserID         string
	FamilyID       string
	DeviceName     string
	Platform       Platform
	AppVersion     string
	CreatedAt      time.Time
	LastSeenAt     *time.Time
	RevokedAt      *time.Time
	LastSyncCursor int64
	LastSyncAt     *time.Time
}

func (d Device) Status() DeviceStatus {
	if d.RevokedAt != nil {
		return DeviceStatusRevoked
	}
	return DeviceStatusActive
}

// DeviceTouch contains server-owned status changes. The service supplies the
// timestamp; clients cannot choose last_seen_at.
type DeviceTouch struct {
	AppVersion string
	SeenAt     time.Time
}

// SyncDeviceDTO is the API-neutral response DTO for device endpoints. The
// additive status/cursor fields support device status and sync progress while
// retaining all fields required by docs/nas/02-api-contract.yaml.
type SyncDeviceDTO struct {
	ID             string       `json:"id"`
	DeviceName     string       `json:"device_name"`
	Platform       Platform     `json:"platform"`
	AppVersion     string       `json:"app_version,omitempty"`
	LastSeenAt     *time.Time   `json:"last_seen_at,omitempty"`
	CreatedAt      time.Time    `json:"created_at"`
	RevokedAt      *time.Time   `json:"revoked_at,omitempty"`
	Status         DeviceStatus `json:"status"`
	LastSyncCursor int64        `json:"last_sync_cursor"`
	LastSyncAt     *time.Time   `json:"last_sync_at,omitempty"`
	IsCurrent      bool         `json:"is_current"`
}

func (d Device) DTO(current bool) SyncDeviceDTO {
	return SyncDeviceDTO{
		ID: d.ID, DeviceName: d.DeviceName, Platform: d.Platform,
		AppVersion: d.AppVersion, LastSeenAt: cloneTime(d.LastSeenAt),
		CreatedAt: d.CreatedAt, RevokedAt: cloneTime(d.RevokedAt),
		Status: d.Status(), LastSyncCursor: d.LastSyncCursor,
		LastSyncAt: cloneTime(d.LastSyncAt), IsCurrent: current,
	}
}

func cloneTime(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	copy := value.UTC()
	return &copy
}
