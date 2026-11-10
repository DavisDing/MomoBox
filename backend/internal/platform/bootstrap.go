package platform

import (
	"context"
	"fmt"
)

// CheckBootstrap runs after the migration advisory lock is acquired. A missing
// or empty ledger is safe to initialize only when no application objects exist.
// Extension-owned objects (for example pgcrypto installed by an administrator)
// are allowed in an otherwise empty schema.
func (tx sqlMigrationTransaction) CheckBootstrap(ctx context.Context) error {
	// MomoBox's shipped migrations target public explicitly. Do not let a
	// caller's search_path hide an existing public schema during detection.
	if _, err := tx.tx.ExecContext(ctx, `SET LOCAL search_path = public`); err != nil {
		return fmt.Errorf("select migration schema: %w", err)
	}
	var ledgerExists bool
	if err := tx.tx.QueryRowContext(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
			WHERE n.nspname = current_schema() AND c.relname = 'schema_migrations'
		)`).Scan(&ledgerExists); err != nil {
		return fmt.Errorf("inspect migration ledger: %w", err)
	}
	if ledgerExists {
		var recorded bool
		if err := tx.tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations)`).Scan(&recorded); err != nil {
			return fmt.Errorf("inspect migration records: %w", err)
		}
		if recorded {
			return nil
		}
	}
	var hasObjects bool
	if err := tx.tx.QueryRowContext(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
			WHERE n.nspname = current_schema() AND c.relname <> 'schema_migrations'
			AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
			AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
			UNION ALL
			SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
			WHERE n.nspname = current_schema()
			AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
			UNION ALL
			SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
			WHERE n.nspname = current_schema() AND t.typtype IN ('e', 'd', 'r')
			AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
		)`).Scan(&hasObjects); err != nil {
		return fmt.Errorf("inspect bootstrap schema: %w", err)
	}
	if hasObjects {
		return ErrUntrackedDatabase
	}
	return nil
}
