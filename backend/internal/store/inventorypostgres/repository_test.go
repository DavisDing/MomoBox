package inventorypostgres

import (
	"strings"
	"testing"

	"github.com/momobox/backend/internal/inventory"
)

func TestStaticSQLKeepsFamilyScopeAndRowLocks(t *testing.T) {
	for name, query := range map[string]string{
		"find many": findBatchesForUpdateSQL,
		"find one":  findBatchForUpdateSQL,
		"update":    applyBatchChangeSQL,
	} {
		if !strings.Contains(query, "family_id = $1::uuid") {
			t.Fatalf("%s query is missing family scope", name)
		}
	}
	if !strings.Contains(findBatchesForUpdateSQL, "FOR UPDATE") || !strings.Contains(findBatchForUpdateSQL, "FOR UPDATE") {
		t.Fatal("batch reads must use FOR UPDATE")
	}
	if !strings.Contains(applyBatchChangeSQL, "quantity + $3 >= 0") {
		t.Fatal("batch update must reject a negative quantity in SQL")
	}
	if !strings.Contains(findIdempotencySQL, "expires_at") || !strings.Contains(findIdempotencySQL, "FOR UPDATE") {
		t.Fatal("inventory idempotency reads must lock and inspect expiry")
	}
	for _, scope := range []string{"family_id = $1::uuid", "device_id = $2::uuid", "idempotency_key = $3"} {
		if !strings.Contains(deleteIdempotencySQL, scope) {
			t.Fatalf("expired idempotency cleanup is missing scope: %s", scope)
		}
	}
}

func TestConsumptionMappingAndKeys(t *testing.T) {
	kind, delta, err := consumptionValues(inventory.CommandConsumeFEFO, 3)
	if err != nil || kind != "consume" || delta != -3 {
		t.Fatalf("unexpected consume mapping: %q %d %v", kind, delta, err)
	}
	kind, delta, err = consumptionValues(inventory.CommandRestock, 2)
	if err != nil || kind != "restock" || delta != 2 {
		t.Fatalf("unexpected restock mapping: %q %d %v", kind, delta, err)
	}
	left := consumptionIdempotencyKey("operation", "batch-a")
	right := consumptionIdempotencyKey("operation", "batch-a")
	if left != right || len(left) < 16 || left == consumptionIdempotencyKey("operation", "batch-b") {
		t.Fatal("consumption record idempotency keys must be stable and batch-specific")
	}
}

func TestDatabaseStatusDoesNotExposeExpiredBatchAsAvailable(t *testing.T) {
	if domainBatchStatus("active") != inventory.BatchAvailable {
		t.Fatal("active batch should be available")
	}
	for _, status := range []string{"expired", "discarded"} {
		if domainBatchStatus(status) != inventory.BatchDiscarded {
			t.Fatalf("%s batch must not be available", status)
		}
	}
}
