package authpostgres

import (
	"context"
	"database/sql"
	"errors"

	"github.com/momobox/backend/internal/store/common"
	"github.com/momobox/backend/internal/syncdevice"
)

// SyncDeviceRepository is the full device-management adapter used by
// syncdevice.Service. The schema must provide sync_devices.last_sync_cursor
// and sync_devices.last_sync_at; see the delivery note for the pending schema
// dependency.
type SyncDeviceRepository struct{ db *sql.DB }

func NewSyncDeviceRepository(db *sql.DB) *SyncDeviceRepository {
	return &SyncDeviceRepository{db: db}
}

const syncDeviceColumns = `
id::text, user_id::text, family_id::text, device_name, platform,
COALESCE(app_version, ''), created_at, last_seen_at, revoked_at,
last_sync_cursor, last_sync_at`

func (r *SyncDeviceRepository) Register(ctx context.Context, device syncdevice.Device) (syncdevice.Device, error) {
	row := r.db.QueryRowContext(ctx, `
		INSERT INTO sync_devices
			(id, family_id, user_id, device_name, platform, app_version,
			 created_at, last_seen_at, last_sync_cursor, last_sync_at)
		SELECT $1::uuid, fm.family_id, fm.user_id, $4, $5, NULLIF($6, ''),
		       $7, $8, $9, $10
		FROM family_members AS fm
		JOIN families AS f ON f.id = fm.family_id AND f.deleted_at IS NULL
		WHERE fm.family_id = $2::uuid
		  AND fm.user_id = $3::uuid
		  AND fm.deleted_at IS NULL
		ON CONFLICT (id) DO UPDATE SET
			device_name = EXCLUDED.device_name,
			platform = EXCLUDED.platform,
			app_version = EXCLUDED.app_version,
			last_seen_at = EXCLUDED.last_seen_at
		WHERE sync_devices.family_id = EXCLUDED.family_id
		  AND sync_devices.user_id = EXCLUDED.user_id
		  AND sync_devices.deleted_at IS NULL
		  AND sync_devices.revoked_at IS NULL
		RETURNING `+syncDeviceColumns,
		device.ID, device.FamilyID, device.UserID, device.DeviceName, device.Platform,
		device.AppVersion, device.CreatedAt, device.LastSeenAt, device.LastSyncCursor, device.LastSyncAt)
	saved, err := scanSyncDevice(row)
	if errors.Is(err, sql.ErrNoRows) {
		return syncdevice.Device{}, syncdevice.ErrConflict
	}
	if common.HasSQLState(err, common.SQLStateUniqueViolation) || common.HasSQLState(err, common.SQLStateForeignKeyViolation) {
		return syncdevice.Device{}, syncdevice.ErrConflict
	}
	return saved, err
}

func (r *SyncDeviceRepository) Get(ctx context.Context, familyID, deviceID string) (syncdevice.Device, error) {
	device, err := scanSyncDevice(r.db.QueryRowContext(ctx, `
		SELECT `+syncDeviceColumns+`
		FROM sync_devices
		WHERE family_id = $1::uuid
		  AND id = $2::uuid
		  AND deleted_at IS NULL`, familyID, deviceID))
	return device, mapSyncDeviceNotFound(err)
}

func (r *SyncDeviceRepository) ListByUser(ctx context.Context, familyID, userID string) ([]syncdevice.Device, error) {
	return r.list(ctx, `
		SELECT `+syncDeviceColumns+`
		FROM sync_devices
		WHERE family_id = $1::uuid
		  AND user_id = $2::uuid
		  AND deleted_at IS NULL
		ORDER BY created_at, id`, familyID, userID)
}

func (r *SyncDeviceRepository) ListByFamily(ctx context.Context, familyID string) ([]syncdevice.Device, error) {
	return r.list(ctx, `
		SELECT `+syncDeviceColumns+`
		FROM sync_devices
		WHERE family_id = $1::uuid
		  AND deleted_at IS NULL
		ORDER BY created_at, id`, familyID)
}

func (r *SyncDeviceRepository) list(ctx context.Context, query string, args ...any) ([]syncdevice.Device, error) {
	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := make([]syncdevice.Device, 0)
	for rows.Next() {
		device, err := scanSyncDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

func (r *SyncDeviceRepository) Revoke(ctx context.Context, familyID, deviceID string, touch syncdevice.DeviceTouch) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE sync_devices
		SET revoked_at = COALESCE(revoked_at, $3),
		    last_seen_at = GREATEST(COALESCE(last_seen_at, $3), $3),
		    app_version = COALESCE(NULLIF($4, ''), app_version)
		WHERE family_id = $1::uuid
		  AND id = $2::uuid
		  AND deleted_at IS NULL`, familyID, deviceID, touch.SeenAt, touch.AppVersion)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return syncdevice.ErrNotFound
	}
	return nil
}

func (r *SyncDeviceRepository) Touch(ctx context.Context, familyID, deviceID string, touch syncdevice.DeviceTouch) (syncdevice.Device, error) {
	device, err := scanSyncDevice(r.db.QueryRowContext(ctx, `
		UPDATE sync_devices
		SET last_seen_at = GREATEST(COALESCE(last_seen_at, $3), $3),
		    app_version = COALESCE(NULLIF($4, ''), app_version)
		WHERE family_id = $1::uuid
		  AND id = $2::uuid
		  AND deleted_at IS NULL
		  AND revoked_at IS NULL
		RETURNING `+syncDeviceColumns, familyID, deviceID, touch.SeenAt, touch.AppVersion))
	if !errors.Is(err, sql.ErrNoRows) {
		return device, err
	}
	return syncdevice.Device{}, r.classifyInactiveDevice(ctx, familyID, deviceID, 0, false)
}

func (r *SyncDeviceRepository) AdvanceSyncCursor(ctx context.Context, familyID, deviceID string, cursor int64, touch syncdevice.DeviceTouch) (syncdevice.Device, error) {
	device, err := scanSyncDevice(r.db.QueryRowContext(ctx, `
		UPDATE sync_devices
		SET last_sync_cursor = $3,
		    last_sync_at = $4,
		    last_seen_at = GREATEST(COALESCE(last_seen_at, $4), $4),
		    app_version = COALESCE(NULLIF($5, ''), app_version)
		WHERE family_id = $1::uuid
		  AND id = $2::uuid
		  AND deleted_at IS NULL
		  AND revoked_at IS NULL
		  AND last_sync_cursor <= $3
		RETURNING `+syncDeviceColumns, familyID, deviceID, cursor, touch.SeenAt, touch.AppVersion))
	if !errors.Is(err, sql.ErrNoRows) {
		return device, err
	}
	return syncdevice.Device{}, r.classifyInactiveDevice(ctx, familyID, deviceID, cursor, true)
}

func (r *SyncDeviceRepository) classifyInactiveDevice(ctx context.Context, familyID, deviceID string, cursor int64, checkCursor bool) error {
	device, err := r.Get(ctx, familyID, deviceID)
	if err != nil {
		return err
	}
	if device.RevokedAt != nil {
		return syncdevice.ErrRevoked
	}
	if checkCursor && device.LastSyncCursor > cursor {
		return syncdevice.ErrCursorRegression
	}
	return syncdevice.ErrConflict
}

type syncDeviceScanner interface{ Scan(...any) error }

func scanSyncDevice(scanner syncDeviceScanner) (syncdevice.Device, error) {
	var device syncdevice.Device
	var lastSeen, revokedAt, lastSyncAt sql.NullTime
	err := scanner.Scan(
		&device.ID, &device.UserID, &device.FamilyID, &device.DeviceName, &device.Platform,
		&device.AppVersion, &device.CreatedAt, &lastSeen, &revokedAt,
		&device.LastSyncCursor, &lastSyncAt,
	)
	if err != nil {
		return syncdevice.Device{}, err
	}
	device.LastSeenAt = timePointer(lastSeen)
	device.RevokedAt = timePointer(revokedAt)
	device.LastSyncAt = timePointer(lastSyncAt)
	return device, nil
}

func mapSyncDeviceNotFound(err error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return syncdevice.ErrNotFound
	}
	return err
}

var _ syncdevice.DeviceRepository = (*SyncDeviceRepository)(nil)
