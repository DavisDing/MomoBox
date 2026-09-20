package familypostgres

import "database/sql"

// Repositories exposes one transaction-capable implementation through each
// domain port expected by family.NewService and auth.NewService.
type Repositories struct {
	Families    *Repository
	Memberships *Repository
	Invites     *Repository
	Joiner      *Repository
}

func NewRepositories(db *sql.DB) Repositories {
	repository := NewRepository(db)
	return Repositories{
		Families:    repository,
		Memberships: repository,
		Invites:     repository,
		Joiner:      repository,
	}
}
