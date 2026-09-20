package syncdevice_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/momobox/backend/internal/syncdevice"
)

var (
	familyA = "11111111-1111-4111-8111-111111111111"
	familyB = "22222222-2222-4222-8222-222222222222"
	userA   = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	userB   = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	deviceA = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
	deviceB = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
	deviceC = "cccccccc-3333-4333-8333-cccccccccccc"
)

type fakeRepository struct {
	devices       map[string]syncdevice.Device
	getFamilies   []string
	listFamilies  []string
	listUsers     []string
	revoked       []string
	touches       []string
	cursorUpdates []string
}

func newFakeRepository(devices ...syncdevice.Device) *fakeRepository {
	repository := &fakeRepository{devices: make(map[string]syncdevice.Device)}
	for _, device := range devices {
		repository.devices[device.ID] = device
	}
	return repository
}

func (r *fakeRepository) Register(_ context.Context, device syncdevice.Device) (syncdevice.Device, error) {
	if existing, ok := r.devices[device.ID]; ok {
		if existing.FamilyID != device.FamilyID || existing.UserID != device.UserID {
			return syncdevice.Device{}, syncdevice.ErrConflict
		}
		return existing, syncdevice.ErrConflict
	}
	r.devices[device.ID] = device
	return device, nil
}

func (r *fakeRepository) Get(_ context.Context, familyID, deviceID string) (syncdevice.Device, error) {
	r.getFamilies = append(r.getFamilies, familyID)
	device, ok := r.devices[deviceID]
	if !ok || device.FamilyID != familyID {
		return syncdevice.Device{}, syncdevice.ErrNotFound
	}
	return device, nil
}

func (r *fakeRepository) ListByUser(_ context.Context, familyID, userID string) ([]syncdevice.Device, error) {
	r.listUsers = append(r.listUsers, familyID+":"+userID)
	var result []syncdevice.Device
	for _, device := range r.devices {
		if device.FamilyID == familyID && device.UserID == userID {
			result = append(result, device)
		}
	}
	return result, nil
}

func (r *fakeRepository) ListByFamily(_ context.Context, familyID string) ([]syncdevice.Device, error) {
	r.listFamilies = append(r.listFamilies, familyID)
	var result []syncdevice.Device
	for _, device := range r.devices {
		if device.FamilyID == familyID {
			result = append(result, device)
		}
	}
	return result, nil
}

func (r *fakeRepository) Revoke(_ context.Context, familyID, deviceID string, touch syncdevice.DeviceTouch) error {
	device, err := r.Get(context.Background(), familyID, deviceID)
	if err != nil {
		return err
	}
	when := touch.SeenAt
	device.RevokedAt = &when
	r.devices[deviceID] = device
	r.revoked = append(r.revoked, deviceID)
	return nil
}

func (r *fakeRepository) Touch(_ context.Context, familyID, deviceID string, touch syncdevice.DeviceTouch) (syncdevice.Device, error) {
	device, err := r.Get(context.Background(), familyID, deviceID)
	if err != nil {
		return syncdevice.Device{}, err
	}
	if device.RevokedAt != nil {
		return syncdevice.Device{}, syncdevice.ErrRevoked
	}
	device.AppVersion = touch.AppVersion
	seenAt := touch.SeenAt
	device.LastSeenAt = &seenAt
	r.devices[deviceID] = device
	r.touches = append(r.touches, deviceID)
	return device, nil
}

func (r *fakeRepository) AdvanceSyncCursor(_ context.Context, familyID, deviceID string, cursor int64, touch syncdevice.DeviceTouch) (syncdevice.Device, error) {
	device, err := r.Get(context.Background(), familyID, deviceID)
	if err != nil {
		return syncdevice.Device{}, err
	}
	if device.RevokedAt != nil {
		return syncdevice.Device{}, syncdevice.ErrRevoked
	}
	if cursor < device.LastSyncCursor {
		return syncdevice.Device{}, syncdevice.ErrCursorRegression
	}
	device.LastSyncCursor = cursor
	when := touch.SeenAt
	device.LastSyncAt = &when
	r.devices[deviceID] = device
	r.cursorUpdates = append(r.cursorUpdates, deviceID)
	return device, nil
}

func fixedClock() time.Time {
	return time.Date(2026, 9, 20, 10, 30, 0, 0, time.FixedZone("CST", 8*60*60))
}

func actor(user, family, device string, role syncdevice.Role) syncdevice.Actor {
	return syncdevice.Actor{UserID: user, FamilyID: family, DeviceID: device, Role: role}
}

func storedDevice(id, user, family string, cursor int64) syncdevice.Device {
	created := fixedClock().UTC().Add(-time.Hour)
	return syncdevice.Device{ID: id, UserID: user, FamilyID: family, DeviceName: "Phone", Platform: syncdevice.PlatformIOS, CreatedAt: created, LastSyncCursor: cursor}
}

func TestRegisterValidatesAndUsesServerTime(t *testing.T) {
	repository := newFakeRepository()
	service := syncdevice.NewService(repository, fixedClock)

	got, err := service.Register(context.Background(), actor(userA, familyA, deviceC, syncdevice.RoleMember), syncdevice.RegisterDeviceRequest{
		DeviceID: deviceC, DeviceName: "  Kitchen iPhone  ", Platform: syncdevice.PlatformIOS, AppVersion: " 1.2.3 ",
	})
	if err != nil {
		t.Fatalf("Register() error = %v", err)
	}
	if got.DeviceName != "Kitchen iPhone" || got.AppVersion != "1.2.3" {
		t.Fatalf("Register() did not normalize metadata: %+v", got)
	}
	if !got.LastSeenAt.Equal(fixedClock().UTC()) || got.LastSyncCursor != 0 || got.Status != syncdevice.DeviceStatusActive {
		t.Fatalf("Register() returned incorrect server state: %+v", got)
	}

	_, err = service.Register(context.Background(), actor(userA, familyA, deviceC, syncdevice.RoleMember), syncdevice.RegisterDeviceRequest{
		DeviceID: deviceC, DeviceName: "", Platform: syncdevice.PlatformIOS,
	})
	if !errors.Is(err, syncdevice.ErrValidation) {
		t.Fatalf("invalid registration error = %v, want validation error", err)
	}
}

func TestListScopesMembersAndAllowsAdminFamilyManagement(t *testing.T) {
	repository := newFakeRepository(
		storedDevice(deviceA, userA, familyA, 2),
		storedDevice(deviceB, userB, familyA, 4),
		storedDevice(deviceC, userA, familyB, 9),
	)
	service := syncdevice.NewService(repository, fixedClock)

	memberDevices, err := service.List(context.Background(), actor(userA, familyA, deviceA, syncdevice.RoleMember))
	if err != nil {
		t.Fatalf("member List() error = %v", err)
	}
	if len(memberDevices) != 1 || memberDevices[0].ID != deviceA {
		t.Fatalf("member saw devices outside ownership: %+v", memberDevices)
	}
	if len(repository.listUsers) != 1 || repository.listUsers[0] != familyA+":"+userA {
		t.Fatalf("member list was not family/user scoped: %v", repository.listUsers)
	}

	adminDevices, err := service.List(context.Background(), actor(userA, familyA, deviceA, syncdevice.RoleAdmin))
	if err != nil {
		t.Fatalf("admin List() error = %v", err)
	}
	if len(adminDevices) != 2 {
		t.Fatalf("admin should see all family devices, got %+v", adminDevices)
	}
	if len(repository.listFamilies) != 1 || repository.listFamilies[0] != familyA {
		t.Fatalf("admin list was not family scoped: %v", repository.listFamilies)
	}
}

func TestMemberCannotRevokeAnotherUsersDeviceButAdminCan(t *testing.T) {
	repository := newFakeRepository(storedDevice(deviceA, userA, familyA, 0), storedDevice(deviceB, userB, familyA, 0))
	service := syncdevice.NewService(repository, fixedClock)

	err := service.Revoke(context.Background(), actor(userA, familyA, deviceA, syncdevice.RoleMember), deviceB)
	if !errors.Is(err, syncdevice.ErrForbidden) {
		t.Fatalf("member revoke error = %v, want forbidden", err)
	}
	if len(repository.revoked) != 0 {
		t.Fatalf("forbidden revoke changed repository: %v", repository.revoked)
	}

	if err := service.Revoke(context.Background(), actor(userA, familyA, deviceA, syncdevice.RoleAdmin), deviceB); err != nil {
		t.Fatalf("admin revoke error = %v", err)
	}
	if len(repository.revoked) != 1 || repository.revoked[0] != deviceB {
		t.Fatalf("admin revoke was not persisted: %v", repository.revoked)
	}
}

func TestCurrentHeartbeatAndCursorAreOwnDeviceOnlyAndMonotonic(t *testing.T) {
	repository := newFakeRepository(storedDevice(deviceA, userA, familyA, 3))
	service := syncdevice.NewService(repository, fixedClock)
	currentActor := actor(userA, familyA, deviceA, syncdevice.RoleMember)

	current, err := service.Current(context.Background(), currentActor)
	if err != nil || current.ID != deviceA || !current.IsCurrent {
		t.Fatalf("Current() = %+v, error = %v", current, err)
	}
	updated, err := service.TouchCurrent(context.Background(), currentActor, syncdevice.TouchCurrentDeviceRequest{AppVersion: "2.0.0"})
	if err != nil || updated.AppVersion != "2.0.0" || len(repository.touches) != 1 {
		t.Fatalf("TouchCurrent() = %+v, error = %v", updated, err)
	}
	updated, err = service.RecordCurrentSync(context.Background(), currentActor, 8)
	if err != nil || updated.LastSyncCursor != 8 || updated.LastSyncAt == nil {
		t.Fatalf("RecordCurrentSync() = %+v, error = %v", updated, err)
	}
	_, err = service.RecordCurrentSync(context.Background(), currentActor, 7)
	if !errors.Is(err, syncdevice.ErrCursorRegression) {
		t.Fatalf("cursor regression error = %v, want cursor regression", err)
	}

	otherDeviceActor := actor(userA, familyA, deviceB, syncdevice.RoleMember)
	_, err = service.Current(context.Background(), otherDeviceActor)
	if !errors.Is(err, syncdevice.ErrCurrentUnavailable) {
		t.Fatalf("unknown current device error = %v, want current unavailable", err)
	}
}

func TestRevokedDeviceCannotReportStatusOrCursor(t *testing.T) {
	revokedAt := fixedClock().UTC()
	device := storedDevice(deviceA, userA, familyA, 5)
	device.RevokedAt = &revokedAt
	repository := newFakeRepository(device)
	service := syncdevice.NewService(repository, fixedClock)
	currentActor := actor(userA, familyA, deviceA, syncdevice.RoleMember)

	_, err := service.TouchCurrent(context.Background(), currentActor, syncdevice.TouchCurrentDeviceRequest{})
	if !errors.Is(err, syncdevice.ErrRevoked) {
		t.Fatalf("revoked TouchCurrent() error = %v, want revoked", err)
	}
	_, err = service.RecordCurrentSync(context.Background(), currentActor, 6)
	if !errors.Is(err, syncdevice.ErrRevoked) {
		t.Fatalf("revoked RecordCurrentSync() error = %v, want revoked", err)
	}
	if len(repository.touches) != 0 || len(repository.cursorUpdates) != 0 {
		t.Fatalf("revoked device was updated: touches=%v cursors=%v", repository.touches, repository.cursorUpdates)
	}
}

func TestCrossFamilyRevokeDoesNotLeakOrMutate(t *testing.T) {
	repository := newFakeRepository(storedDevice(deviceC, userA, familyB, 0))
	service := syncdevice.NewService(repository, fixedClock)

	err := service.Revoke(context.Background(), actor(userA, familyA, deviceA, syncdevice.RoleOwner), deviceC)
	if !errors.Is(err, syncdevice.ErrNotFound) {
		t.Fatalf("cross-family revoke error = %v, want not found", err)
	}
	if len(repository.revoked) != 0 {
		t.Fatalf("cross-family revoke mutated repository: %v", repository.revoked)
	}
	if len(repository.getFamilies) != 1 || repository.getFamilies[0] != familyA {
		t.Fatalf("cross-family lookup was not scoped: %v", repository.getFamilies)
	}
}
