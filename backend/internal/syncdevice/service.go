package syncdevice

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"
)

// Clock is injectable to keep the business service deterministic in tests.
type Clock func() time.Time

// Service contains pure sync-device use cases. It does not know about HTTP,
// SQL, Home Assistant, or token parsing.
type Service struct {
	repository DeviceRepository
	clock      Clock
}

func NewService(repository DeviceRepository, clock Clock) *Service {
	if clock == nil {
		clock = func() time.Time { return time.Now().UTC() }
	}
	return &Service{repository: repository, clock: clock}
}

// Register registers one MomoBox client device in the actor's current family.
// Re-registration and uniqueness semantics are delegated to the repository,
// but a revoked device must not be silently reactivated by this service.
func (s *Service) Register(ctx context.Context, actor Actor, request RegisterDeviceRequest) (SyncDeviceDTO, error) {
	if err := validateActor(actor); err != nil {
		return SyncDeviceDTO{}, err
	}
	if err := validateRegisterRequest(request); err != nil {
		return SyncDeviceDTO{}, err
	}
	now := normalizeNow(s.clock())
	device := Device{
		ID: request.DeviceID, UserID: actor.UserID, FamilyID: actor.FamilyID,
		DeviceName: strings.TrimSpace(request.DeviceName), Platform: request.Platform,
		AppVersion: strings.TrimSpace(request.AppVersion), CreatedAt: now,
		LastSeenAt: timePointer(now), LastSyncCursor: 0,
	}
	saved, err := s.repository.Register(ctx, device)
	if err != nil {
		return SyncDeviceDTO{}, translateRepositoryError(err)
	}
	if saved.FamilyID != actor.FamilyID || saved.UserID != actor.UserID || saved.ID != device.ID {
		return SyncDeviceDTO{}, ErrConflict
	}
	return saved.DTO(saved.ID == actor.DeviceID), nil
}

// List returns all family devices for owner/admin and only the caller's own
// devices for a member. Revoked devices remain visible for device-management
// and audit purposes.
func (s *Service) List(ctx context.Context, actor Actor) ([]SyncDeviceDTO, error) {
	if err := validateActor(actor); err != nil {
		return nil, err
	}
	var (
		devices []Device
		err     error
	)
	if actor.Role == RoleOwner || actor.Role == RoleAdmin {
		devices, err = s.repository.ListByFamily(ctx, actor.FamilyID)
	} else {
		devices, err = s.repository.ListByUser(ctx, actor.FamilyID, actor.UserID)
	}
	if err != nil {
		return nil, translateRepositoryError(err)
	}
	for _, device := range devices {
		if device.FamilyID != actor.FamilyID {
			return nil, ErrNotFound
		}
		if actor.Role == RoleMember && device.UserID != actor.UserID {
			return nil, ErrForbidden
		}
	}
	sort.SliceStable(devices, func(i, j int) bool {
		if devices[i].CreatedAt.Equal(devices[j].CreatedAt) {
			return devices[i].ID < devices[j].ID
		}
		return devices[i].CreatedAt.Before(devices[j].CreatedAt)
	})
	result := make([]SyncDeviceDTO, 0, len(devices))
	for _, device := range devices {
		result = append(result, device.DTO(device.ID == actor.DeviceID))
	}
	return result, nil
}

// ListResponse is the contract-shaped wrapper for adapters that expose the
// GET /devices response object.
func (s *Service) ListResponse(ctx context.Context, actor Actor) (DeviceListResponse, error) {
	devices, err := s.List(ctx, actor)
	if err != nil {
		return DeviceListResponse{}, err
	}
	return DeviceListResponse{Devices: devices}, nil
}

// Current returns the device identified by the authenticated token. It never
// accepts a client-supplied target ID, preventing one device from masquerading
// as another when reporting status or sync progress.
func (s *Service) Current(ctx context.Context, actor Actor) (SyncDeviceDTO, error) {
	if err := validateActor(actor); err != nil {
		return SyncDeviceDTO{}, err
	}
	if err := validateDeviceID(actor.DeviceID); err != nil {
		return SyncDeviceDTO{}, ErrCurrentUnavailable
	}
	device, err := s.repository.Get(ctx, actor.FamilyID, actor.DeviceID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return SyncDeviceDTO{}, ErrCurrentUnavailable
		}
		return SyncDeviceDTO{}, translateRepositoryError(err)
	}
	if err := authorizeOwnCurrentDevice(actor, device); err != nil {
		if errors.Is(err, ErrNotFound) {
			return SyncDeviceDTO{}, ErrCurrentUnavailable
		}
		return SyncDeviceDTO{}, err
	}
	return device.DTO(true), nil
}

// Revoke revokes a device within the current family. Members can revoke only
// their own devices; owner/admin can revoke any family device. Revoke is
// idempotent at the service boundary.
func (s *Service) Revoke(ctx context.Context, actor Actor, deviceID string) error {
	if err := validateActor(actor); err != nil {
		return err
	}
	if err := validateDeviceID(deviceID); err != nil {
		return err
	}
	device, err := s.repository.Get(ctx, actor.FamilyID, deviceID)
	if err != nil {
		return translateRepositoryError(err)
	}
	if err := authorizeDevice(actor, device); err != nil {
		return err
	}
	if device.RevokedAt != nil {
		return nil
	}
	now := normalizeNow(s.clock())
	if err := s.repository.Revoke(ctx, actor.FamilyID, deviceID, DeviceTouch{SeenAt: now}); err != nil {
		return translateRepositoryError(err)
	}
	return nil
}

// TouchCurrent records a server-side heartbeat and optionally the current app
// version. It cannot change a revoked device back to active.
func (s *Service) TouchCurrent(ctx context.Context, actor Actor, request TouchCurrentDeviceRequest) (SyncDeviceDTO, error) {
	current, err := s.Current(ctx, actor)
	if err != nil {
		return SyncDeviceDTO{}, err
	}
	if current.Status == DeviceStatusRevoked {
		return SyncDeviceDTO{}, ErrRevoked
	}
	if len([]rune(request.AppVersion)) > maxAppVersionLength {
		return SyncDeviceDTO{}, &ValidationError{Field: "app_version", Reason: "is too long"}
	}
	now := normalizeNow(s.clock())
	appVersion := current.AppVersion
	if strings.TrimSpace(request.AppVersion) != "" {
		appVersion = strings.TrimSpace(request.AppVersion)
	}
	updated, err := s.repository.Touch(ctx, actor.FamilyID, actor.DeviceID, DeviceTouch{
		AppVersion: appVersion, SeenAt: now,
	})
	if err != nil {
		return SyncDeviceDTO{}, translateRepositoryError(err)
	}
	return updated.DTO(true), nil
}

// RecordCurrentSync advances the current device's last acknowledged server
// cursor. Cursors are monotonic; a lower cursor is rejected rather than
// silently moving the device backwards.
func (s *Service) RecordCurrentSync(ctx context.Context, actor Actor, cursor int64) (SyncDeviceDTO, error) {
	current, err := s.Current(ctx, actor)
	if err != nil {
		return SyncDeviceDTO{}, err
	}
	if current.Status == DeviceStatusRevoked {
		return SyncDeviceDTO{}, ErrRevoked
	}
	if err := validateCursor(cursor); err != nil {
		return SyncDeviceDTO{}, err
	}
	if cursor < current.LastSyncCursor {
		return SyncDeviceDTO{}, ErrCursorRegression
	}
	now := normalizeNow(s.clock())
	updated, err := s.repository.AdvanceSyncCursor(ctx, actor.FamilyID, actor.DeviceID, cursor, DeviceTouch{SeenAt: now})
	if err != nil {
		return SyncDeviceDTO{}, translateRepositoryError(err)
	}
	return updated.DTO(true), nil
}

func timePointer(value time.Time) *time.Time {
	value = value.UTC()
	return &value
}
