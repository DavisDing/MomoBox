package sync

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

const importTestID = "10000000-0000-4000-8000-000000000001"
const importTestProduct = "20000000-0000-4000-8000-000000000001"
const importTestBatch = "30000000-0000-4000-8000-000000000001"

func validImportFixture(t *testing.T) ImportRequest {
	t.Helper()
	var request ImportRequest
	err := json.Unmarshal([]byte(`{"format_version":1,"device_id":"10000000-0000-4000-8000-000000000002","import_id":"`+importTestID+`","local_workspace_id":"local-one","categories":[],"products":[{"id":"`+importTestProduct+`","name":"Milk","unit":"件","location":"Pantry","low_stock_threshold":2}],"product_batches":[{"id":"`+importTestBatch+`","product_id":"`+importTestProduct+`","quantity":5,"initial_quantity":12,"status":"active","expiry_date":"2026-10-22","is_opened":true,"batch_no":"original"}],"shopping_items":[],"reminder_settings":[],"history":[{"id":"40000000-0000-4000-8000-000000000001","product_id":"`+importTestProduct+`","batch_id":null,"type":"consume","quantity":-7,"occurred_at":"2026-10-21T23:00:00+08:00"}]}`), &request)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

func TestImportFingerprintKeepsManifestAndIgnoresTransportDevice(t *testing.T) {
	request := validImportFixture(t)
	one, err := ValidateImport(request)
	if err != nil {
		t.Fatal(err)
	}
	request.DeviceID = "10000000-0000-4000-8000-000000000003"
	two, err := ValidateImport(request)
	if err != nil || one != two {
		t.Fatalf("device changed source fingerprint: %v", err)
	}
	request.ProductBatches[0]["quantity"] = float64(4)
	three, err := ValidateImport(request)
	if err != nil || three == one {
		t.Fatal("changed current quantity must change manifest fingerprint")
	}
}

func TestImportValidationRejectsLossyAndInvalidRecords(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*ImportRequest)
	}{
		{"format", func(r *ImportRequest) { r.FormatVersion = 2 }},
		{"unknown field", func(r *ImportRequest) { r.Products[0]["picture"] = "silently lost" }},
		{"compound field", func(r *ImportRequest) { r.Products[0]["id name"] = "silently lost" }},
		{"compound enum", func(r *ImportRequest) { r.ProductBatches[0]["date_source"] = "manual barcode" }},
		{"zero calendar year", func(r *ImportRequest) { r.ProductBatches[0]["produced_date"] = "0000-01-01" }},
		{"timestamp as calendar", func(r *ImportRequest) { r.ProductBatches[0]["expiry_date"] = "2026-10-22T00:00:00Z" }},
		{"invalid calendar", func(r *ImportRequest) { r.ProductBatches[0]["expiry_date"] = "2026-02-30" }},
		{"fraction quantity", func(r *ImportRequest) { r.ProductBatches[0]["quantity"] = 0.5 }},
		{"initial lower than current", func(r *ImportRequest) { r.ProductBatches[0]["initial_quantity"] = float64(4) }},
		{"discarded positive", func(r *ImportRequest) { r.ProductBatches[0]["status"] = "discarded" }},
		{"missing quantity", func(r *ImportRequest) { delete(r.ProductBatches[0], "quantity") }},
		{"overflow", func(r *ImportRequest) { r.ProductBatches[0]["initial_quantity"] = float64(2147483648) }},
		{"duplicate UUID", func(r *ImportRequest) { r.Products = append(r.Products, r.Products[0]) }},
		{"history missing instant", func(r *ImportRequest) { r.History[0]["occurred_at"] = "2026-10-22" }},
		{"history wrong sign", func(r *ImportRequest) { r.History[0]["quantity"] = float64(7) }},
		{"unknown history type", func(r *ImportRequest) { r.History[0]["type"] = "mystery" }},
		{"bad timezone", func(r *ImportRequest) { r.History[0]["source_time_zone"] = "Local" }},
		{"unsupported opened reminder", func(r *ImportRequest) {
			r.ReminderSettings = []map[string]any{{"id": importTestID, "opened_warning_days": float64(1)}}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := validImportFixture(t)
			test.mutate(&request)
			if _, err := ValidateImport(request); err == nil {
				t.Fatal("invalid import was accepted")
			}
		})
	}
}

func TestImportZeroAndDiscardedBaselinesRemainExpressible(t *testing.T) {
	for _, status := range []string{"used_up", "discarded", "expired"} {
		request := validImportFixture(t)
		request.ProductBatches[0]["status"] = status
		request.ProductBatches[0]["quantity"] = float64(0)
		if _, err := ValidateImport(request); err != nil {
			t.Fatalf("%s zero baseline rejected: %v", status, err)
		}
	}
	request := validImportFixture(t)
	request.ProductBatches[0]["quantity"] = float64(0)
	request.ProductBatches[0]["initial_quantity"] = float64(0)
	request.ProductBatches[0]["status"] = "used_up"
	if _, err := ValidateImport(request); err != nil {
		t.Fatal(err)
	}
}

func TestImportBoundsAreEnforced(t *testing.T) {
	request := validImportFixture(t)
	request.Products = nil
	for i := 0; i < MaxImportRecords; i++ {
		request.Products = append(request.Products, map[string]any{
			"id": strings.Replace(importTestProduct, "000000000001", leftPadImport(i+1), 1), "name": "Milk",
		})
	}
	if _, err := ValidateImport(request); err == nil {
		t.Fatal("manifest over total bound accepted")
	}
	request = validImportFixture(t)
	request.Products[0]["name"] = strings.Repeat("m", 256)
	if _, err := ValidateImport(request); err == nil {
		t.Fatal("oversized name accepted")
	}
}

func leftPadImport(value int) string {
	digits := ""
	for value > 0 {
		digits = string(rune('0'+value%10)) + digits
		value /= 10
	}
	return strings.Repeat("0", 12-len(digits)) + digits
}

type importScopeFixture struct {
	Repository
	InitialImportRepository
	scope DeviceScope
	calls int
}

func (r *importScopeFixture) ResolveDevice(context.Context, string) (DeviceScope, error) {
	return r.scope, nil
}

func (r *importScopeFixture) PreflightImport(_ context.Context, _ DeviceScope, request ImportRequest, fingerprint string) (ImportReceipt, error) {
	r.calls++
	return ImportReceipt{ImportID: request.ImportID, Fingerprint: fingerprint}, nil
}

func TestImportRechecksDeviceAccountFamilyAndRole(t *testing.T) {
	for _, test := range []struct {
		name  string
		scope DeviceScope
	}{
		{"member", DeviceScope{DeviceID: importTestID, UserID: "u", FamilyID: "f", Role: "member"}},
		{"other user", DeviceScope{DeviceID: importTestID, UserID: "other", FamilyID: "f", Role: "owner"}},
		{"other family", DeviceScope{DeviceID: importTestID, UserID: "u", FamilyID: "other", Role: "owner"}},
		{"revoked", DeviceScope{DeviceID: importTestID, UserID: "u", FamilyID: "f", Role: "owner", Revoked: true}},
	} {
		t.Run(test.name, func(t *testing.T) {
			repository := &importScopeFixture{scope: test.scope}
			_, err := NewService(repository).PreflightImport(context.Background(), DeviceScope{
				DeviceID: importTestID, UserID: "u", FamilyID: "f",
			}, validImportFixture(t))
			var business *BusinessError
			if !errors.As(err, &business) || business.Code != "FORBIDDEN" || repository.calls != 0 {
				t.Fatalf("scope bypass: calls=%d err=%v", repository.calls, err)
			}
		})
	}
}

func TestImportAcceptsLegacyAdjustmentAndZeroDiscardHistory(t *testing.T) {
	for _, kind := range []string{"adjust", "adjustment", "discard"} {
		request := validImportFixture(t)
		request.History[0]["type"] = kind
		if kind == "discard" {
			request.History[0]["quantity"] = float64(0)
		}
		if _, err := ValidateImport(request); err != nil {
			t.Fatalf("%s history rejected: %v", kind, err)
		}
	}
	for _, kind := range []string{"intake", "consume", "restock", "adjust", "adjustment"} {
		request := validImportFixture(t)
		request.History[0]["type"] = kind
		request.History[0]["quantity"] = float64(0)
		if _, err := ValidateImport(request); err == nil {
			t.Fatalf("zero %s accepted outside state-only discard", kind)
		}
	}
}
