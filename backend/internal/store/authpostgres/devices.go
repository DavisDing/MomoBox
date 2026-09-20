package authpostgres

import (
	"context"
	"database/sql"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/store/common"
)

type DeviceRepository struct{ db *sql.DB }

func NewDeviceRepository(db *sql.DB) *DeviceRepository { return &DeviceRepository{db: db} }

func (r *DeviceRepository) ListUserDevices(ctx context.Context, userID string) ([]auth.SyncDevice, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT d.id::text, d.device_name, d.platform, COALESCE(d.app_version, ''),
		       d.last_seen_at, d.created_at, d.revoked_at
		FROM sync_devices AS d
		JOIN users AS u
		  ON u.id = d.user_id
		 AND u.current_family_id = d.family_id
		 AND u.deleted_at IS NULL
		WHERE d.user_id = $1::uuid
		  AND d.deleted_at IS NULL
		ORDER BY d.created_at, d.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := make([]auth.SyncDevice, 0)
	for rows.Next() {
		var device auth.SyncDevice
		var lastSeen, revoked sql.NullTime
		if err := rows.Scan(&device.ID, &device.DeviceName, &device.Platform, &device.AppVersion,
			&lastSeen, &device.CreatedAt, &revoked); err != nil {
			return nil, err
		}
		device.LastSeenAt = timePointer(lastSeen)
		device.RevokedAt = timePointer(revoked)
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

// UpsertDevice writes only inside the family selected by the auth service.
// The INSERT .. SELECT membership guard prevents a caller from attaching a
// device to a family in which the user has no active membership.
func (r *DeviceRepository) UpsertDevice(ctx context.Context, record auth.DeviceRecord) error {
	result, err := r.db.ExecContext(ctx, `
		INSERT INTO sync_devices
			(id, family_id, user_id, device_name, platform, app_version, last_seen_at, created_at)
		SELECT $1::uuid, fm.family_id, fm.user_id, $4, $5, NULLIF($6, ''), COALESCE($7, $8), $8
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
		  AND sync_devices.revoked_at IS NULL`,
		record.ID, record.FamilyID, record.UserID, record.DeviceName, record.Platform,
		record.AppVersion, record.LastSeenAt, record.CreatedAt)
	if common.HasSQLState(err, common.SQLStateForeignKeyViolation) {
		return &auth.ServiceError{Code: auth.CodeConflict, Message: "device family membership is not active", Cause: err}
	}
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return &auth.ServiceError{Code: auth.CodeConflict, Message: "device scope is unavailable, belongs to another user, or is revoked"}
	}
	return nil
}

func timePointer(value sql.NullTime) *time.Time {
	if !value.Valid {
		return nil
	}
	t := value.Time.UTC()
	return &t
}

var _ auth.DeviceReader = (*DeviceRepository)(nil)
