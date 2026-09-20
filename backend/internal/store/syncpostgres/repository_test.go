package syncpostgres

import (
	"strings"
	"testing"
)

func TestEntitySpecsAreHardCodedAndBatchQuantityIsProtected(t *testing.T) {
	for _, entity := range bootstrapEntities {
		spec, ok := entitySpecs[entity]
		if !ok || spec.table == "" {
			t.Fatalf("missing entity spec for %s", entity)
		}
		query := buildUpdateSQL(spec)
		if !strings.Contains(query, "family_id = $2::uuid") || !strings.Contains(query, "version = $5") {
			t.Fatalf("%s update lacks family/version guard", entity)
		}
	}
	batchQuery := buildUpdateSQL(entitySpecs["product_batches"])
	for _, forbidden := range []string{"quantity =", "initial_quantity =", "status ="} {
		if strings.Contains(batchQuery, forbidden) {
			t.Fatalf("ordinary batch upsert can mutate protected field: %s", forbidden)
		}
	}
	if !containsProtectedBatchQuantity(map[string]any{"quantity": 1}) || !containsProtectedBatchQuantity(map[string]any{"status": "discarded"}) {
		t.Fatal("protected batch fields must be rejected in depth")
	}
}

func TestStaticSyncSQLScopesCursorAndIdempotencyByFamily(t *testing.T) {
	for name, query := range map[string]string{
		"cursor":      currentCursorSQL,
		"pull":        pullSQL,
		"idempotency": readIdempotencySQL,
		"change":      appendChangeSQL,
		"conflict":    insertConflictSQL,
	} {
		if !strings.Contains(query, "family_id") {
			t.Fatalf("%s SQL is not family-scoped", name)
		}
	}
	if !strings.Contains(pullSQL, "cursor > $2") || !strings.Contains(pullSQL, "ORDER BY cursor ASC") {
		t.Fatal("pull SQL must implement a monotonic cursor")
	}
	if !strings.Contains(lockIdempotencySQL, "pg_advisory_xact_lock") || !strings.Contains(readIdempotencySQL, "FOR UPDATE") {
		t.Fatal("idempotency must be serialized inside the transaction")
	}
}

func TestRequiredInsertValidation(t *testing.T) {
	if err := validateRequiredPayload(entitySpecs["products"], map[string]any{}, true); err == nil {
		t.Fatal("new products require a name")
	}
	if err := validateRequiredPayload(entitySpecs["products"], map[string]any{"name": "Milk"}, true); err != nil {
		t.Fatalf("valid product rejected: %v", err)
	}
	if err := validateRequiredPayload(entitySpecs["products"], map[string]any{}, false); err != nil {
		t.Fatalf("partial update should not require name: %v", err)
	}
}
