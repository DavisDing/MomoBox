package authpostgres

import "database/sql"

type Repositories struct {
	Users         *UserRepository
	RefreshTokens *RefreshTokenRepository
	Devices       *DeviceRepository
	SyncDevices   *SyncDeviceRepository
}

func NewRepositories(db *sql.DB) Repositories {
	return Repositories{
		Users:         NewUserRepository(db),
		RefreshTokens: NewRefreshTokenRepository(db),
		Devices:       NewDeviceRepository(db),
		SyncDevices:   NewSyncDeviceRepository(db),
	}
}
