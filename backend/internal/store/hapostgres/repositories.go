package hapostgres

// Repositories groups the Home Assistant persistence adapters for the
// composition root. All members share the same database pool.
type Repositories struct {
	Integrations *IntegrationRepository
	Devices      *DeviceRepository
	Entities     *EntityRepository
	Permissions  *PermissionRepository
	Audit        *AuditRepository
}

func NewRepositories(db DB, actorResolver ...ActorResolver) Repositories {
	return Repositories{
		Integrations: NewIntegrationRepository(db, actorResolver...),
		Devices:      NewDeviceRepository(db),
		Entities:     NewEntityRepository(db),
		Permissions:  NewPermissionRepository(db),
		Audit:        NewAuditRepository(db),
	}
}
