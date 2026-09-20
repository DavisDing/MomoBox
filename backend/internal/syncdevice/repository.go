package syncdevice

import "context"

// DeviceRepository is the persistence boundary for sync_devices. Every read
// and write that addresses a resource takes familyID so a caller cannot query
// a device by global ID alone. Implementations should enforce the same scope
// in SQL and in their transaction layer.
type DeviceRepository interface {
	Register(ctx context.Context, device Device) (Device, error)
	Get(ctx context.Context, familyID, deviceID string) (Device, error)
	ListByUser(ctx context.Context, familyID, userID string) ([]Device, error)
	ListByFamily(ctx context.Context, familyID string) ([]Device, error)
	Revoke(ctx context.Context, familyID, deviceID string, revokedAt DeviceTouch) error
	Touch(ctx context.Context, familyID, deviceID string, touch DeviceTouch) (Device, error)
	AdvanceSyncCursor(ctx context.Context, familyID, deviceID string, cursor int64, syncedAt DeviceTouch) (Device, error)
}

// Repository is kept as a concise alias for callers that prefer the generic
// repository name. It remains the sync_devices repository, never HA storage.
type Repository = DeviceRepository
