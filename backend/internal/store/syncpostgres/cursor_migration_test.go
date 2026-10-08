package syncpostgres

import (
    "os"
    "strings"
    "testing"
)

// This is a migration contract test, not a substitute for concurrent sessions
// against PostgreSQL. It prevents regression to a row trigger (too late for
// identity allocation), per-session sequence caching, or rewriting old policy.
func TestCursorAndReminderMigrationContract(t *testing.T) {
    raw, err := os.ReadFile("../../../migrations/0005_reminder_defaults_and_cursor_order.sql")
    if err != nil {
        t.Fatal(err)
    }
    migration := string(raw)
    for _, required := range []string{
        "ALTER TABLE reminder_settings ALTER COLUMN expiry_warning_days SET DEFAULT 30",
        "pg_advisory_xact_lock(hashtextextended('momobox:change_log:cursor-order', 0))",
        "BEFORE INSERT ON change_log", "FOR EACH STATEMENT", "CACHE 1",
    } {
        if !strings.Contains(migration, required) {
            t.Fatalf("migration missing %q", required)
        }
    }
    if strings.Contains(migration, "FOR EACH ROW") || strings.Contains(migration, "UPDATE reminder_settings") {
        t.Fatal("migration must preserve old reminder values and lock before row defaults")
    }
}

func TestNewReminderInsertDefaultsToThirtyDays(t *testing.T) {
    query := buildInsertSQL(entitySpecs["reminder_settings"])
    if !strings.Contains(query, "COALESCE(($3::jsonb ->> 'expiry_warning_days')::integer, 30)") {
        t.Fatal("sync inserts must share the migration's thirty-day default")
    }
    if strings.Contains(buildUpdateSQL(entitySpecs["reminder_settings"]), "integer, 30") {
        t.Fatal("partial updates must not replace an existing seven-day setting")
    }
}
