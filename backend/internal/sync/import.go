package sync

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"
	"unicode/utf8"
)

const MaxImportRecords = 1000
const MaxImportBytes = 1 << 20

type ImportRequest struct {
	FormatVersion	int	`json:"format_version"`
	DeviceID	string	`json:"device_id"`
	ImportID	string	`json:"import_id"`
	LocalWorkspaceID	string	`json:"local_workspace_id"`
	UnsettledOutboxCount	int	`json:"unsettled_outbox_count"`
	Categories	[]map[string]any	`json:"categories"`
	Products	[]map[string]any	`json:"products"`
	ProductBatches	[]map[string]any	`json:"product_batches"`
	ShoppingItems	[]map[string]any	`json:"shopping_items"`
	ReminderSettings	[]map[string]any	`json:"reminder_settings"`
	History	[]map[string]any	`json:"history"`
}

func (r ImportRequest) Entities() map[string][]map[string]any {
	return map[string][]map[string]any{"categories": r.Categories, "products": r.Products, "product_batches": r.ProductBatches, "shopping_items": r.ShoppingItems, "reminder_settings": r.ReminderSettings, "history": r.History}
}

type ImportConfirmRequest struct {
	DeviceID	string	`json:"device_id"`
	Checkpoint	string	`json:"checkpoint"`
	Fingerprint	string	`json:"fingerprint"`
	UnsettledOutboxCount	int	`json:"unsettled_outbox_count"`
}

type ImportBlocker struct {
	Code	string	`json:"code"`
	Entity	string	`json:"entity,omitempty"`
	EntityID	string	`json:"entity_id,omitempty"`
	Message	string	`json:"message"`
}

type ImportReceipt struct {
	ImportID	string	`json:"import_id"`
	Status	string	`json:"status"`
	Ready	bool	`json:"ready"`
	Checkpoint	string	`json:"checkpoint,omitempty"`
	Fingerprint	string	`json:"fingerprint"`
	Counts	map[string]int	`json:"counts"`
	Blockers	[]ImportBlocker	`json:"blockers"`
	FamilyTimeZone	string	`json:"family_time_zone"`
	ServerCursor	int64	`json:"server_cursor"`
	HistoryCursor	int64	`json:"history_cursor"`
	CompletedAt	string	`json:"completed_at,omitempty"`
}

type ImportCapabilities struct {
	ImportFormatVersion	int	`json:"import_format_version"`
	AtomicImport	bool	`json:"atomic_import"`
	MaxRecords	int	`json:"max_records"`
	MaxRequestBytes	int	`json:"max_request_bytes"`
	HistoryArchive	bool	`json:"history_archive"`
	CalendarDates	bool	`json:"calendar_dates"`
	FamilyTimeZone	string	`json:"family_time_zone"`
}

type ImportHistoryRequest struct {
	After int64
	Until int64
	Limit int
}
type ImportHistoryPage struct {
	Records	[]map[string]any	`json:"records"`
	NextCursor	int64	`json:"next_cursor"`
	Until	int64	`json:"until"`
	HasMore	bool	`json:"has_more"`
}

type InitialImportRepository interface {
	ImportCapabilities(context.Context, DeviceScope) (ImportCapabilities, error)
	PreflightImport(context.Context, DeviceScope, ImportRequest, string) (ImportReceipt, error)
	ConfirmImport(context.Context, DeviceScope, string, ImportConfirmRequest) (ImportReceipt, error)
	ImportReceipt(context.Context, DeviceScope, string) (ImportReceipt, error)
	ImportHistory(context.Context, DeviceScope, ImportHistoryRequest) (ImportHistoryPage, error)
}

func (s *Service) importScope(ctx context.Context, actor DeviceScope, write bool) (DeviceScope, InitialImportRepository, error) {
	if err := validateDeviceID(actor.DeviceID); err != nil {
		return DeviceScope{}, nil, err
	}
	scope, err := s.repository.ResolveDevice(ctx, actor.DeviceID)
	if err != nil {
		return DeviceScope{}, nil, err
	}
	if scope.Revoked || scope.UserID != actor.UserID || scope.FamilyID != actor.FamilyID || scope.Role == "" {
		return DeviceScope{}, nil, NewBusinessError("FORBIDDEN", "current device membership is required", nil)
	}
	if write && scope.Role != "owner" && scope.Role != "admin" {
		return DeviceScope{}, nil, NewBusinessError("FORBIDDEN", "only an owner or admin can import", nil)
	}
	repository, ok := s.repository.(InitialImportRepository)
	if !ok {
		return DeviceScope{}, nil, NewBusinessError("IMPORT_NOT_AVAILABLE", "initial import is not available", nil)
	}
	return scope, repository, nil
}

func (s *Service) ImportCapabilities(ctx context.Context, actor DeviceScope) (ImportCapabilities, error) {
	scope, repository, err := s.importScope(ctx, actor, false)
	if err != nil {
		return ImportCapabilities{}, err
	}
	return repository.ImportCapabilities(ctx, scope)
}

func (s *Service) PreflightImport(ctx context.Context, actor DeviceScope, request ImportRequest) (ImportReceipt, error) {
	scope, repository, err := s.importScope(ctx, actor, true)
	if err != nil {
		return ImportReceipt{}, err
	}
	fingerprint, err := ValidateImport(request)
	if err != nil {
		return ImportReceipt{}, err
	}
	return repository.PreflightImport(ctx, scope, request, fingerprint)
}

func (s *Service) ConfirmImport(ctx context.Context, actor DeviceScope, id string, request ImportConfirmRequest) (ImportReceipt, error) {
	scope, repository, err := s.importScope(ctx, actor, true)
	if err != nil {
		return ImportReceipt{}, err
	}
	if !importUUID(id) || !importUUID(request.Checkpoint) || len(request.Fingerprint) != 64 || request.UnsettledOutboxCount != 0 {
		return ImportReceipt{}, NewBusinessError("VALIDATION_FAILED", "a stable import identity, confirmation and settled outbox are required", nil)
	}
	return repository.ConfirmImport(ctx, scope, id, request)
}

func (s *Service) ImportReceipt(ctx context.Context, actor DeviceScope, id string) (ImportReceipt, error) {
	scope, repository, err := s.importScope(ctx, actor, false)
	if err != nil {
		return ImportReceipt{}, err
	}
	if !importUUID(id) {
		return ImportReceipt{}, ErrInvalidRequest
	}
	return repository.ImportReceipt(ctx, scope, id)
}

func (s *Service) ImportHistory(ctx context.Context, actor DeviceScope, request ImportHistoryRequest) (ImportHistoryPage, error) {
	scope, repository, err := s.importScope(ctx, actor, false)
	if err != nil {
		return ImportHistoryPage{}, err
	}
	if request.After < 0 || request.Until < 0 || (request.Until != 0 && request.After > request.Until) || request.Limit < 1 || request.Limit > 500 {
		return ImportHistoryPage{}, ErrInvalidRequest
	}
	return repository.ImportHistory(ctx, scope, request)
}

var importFields = map[string]string{
	"categories": "id name color sort_order reuse_existing created_at updated_at",
	"products": "id name barcode brand specification category_id identity_key notes location unit low_stock_threshold created_at updated_at",
	"product_batches": "id product_id produced_date expiry_date date_source date_precision initial_quantity quantity unit batch_no is_opened opened_date expiry_after_opening_days status storage_location supplier price created_at updated_at",
	"shopping_items": "id product_id name desired_quantity checked checked_at notes category reason created_at updated_at",
	"reminder_settings": "id product_id enabled expiry_warning_days low_stock_threshold opened_warning_days created_at updated_at",
	"history": "id product_id batch_id type quantity note occurred_at source_time_zone",
}

// ValidateImport rejects unsupported fields rather than silently dropping data.
// Fingerprints deliberately exclude the transport device and local queue count.
func ValidateImport(request ImportRequest) (string, error) {
	if request.FormatVersion != 1 {
		return "", NewBusinessError("IMPORT_UNSUPPORTED_FORMAT", "import format version 1 is required", nil)
	}
	if !importUUID(request.ImportID) || strings.TrimSpace(request.LocalWorkspaceID) == "" || len(request.LocalWorkspaceID) > 255 || request.UnsettledOutboxCount < 0 {
		return "", NewBusinessError("VALIDATION_FAILED", "import identity or workspace is invalid", nil)
	}
	count := 0
	for entity, rows := range request.Entities() {
		count += len(rows)
		ids := map[string]bool{}
		for _, row := range rows {
			id, _ := row["id"].(string)
			if !importUUID(id) || ids[id] {
				return "", invalidImport(entity, id, "UUID is invalid or repeated")
			}
			ids[id] = true
			for field, value := range row {
				if !importContains(importFields[entity], field) {
					return "", invalidImport(entity, id, "unsupported field "+field)
				}
				if err := validateImportField(field, value); err != nil {
					return "", invalidImport(entity, id, err.Error())
				}
			}
			if err := validateImportRow(entity, row); err != nil {
				return "", invalidImport(entity, id, err.Error())
			}
		}
	}
	if count > MaxImportRecords {
		return "", NewBusinessError("IMPORT_LIMIT_EXCEEDED", "atomic import is limited to 1000 records", nil)
	}
	request.DeviceID = ""
	request.UnsettledOutboxCount = 0
	raw, err := json.Marshal(request)
	if err != nil {
		return "", err
	}
	if len(raw) > MaxImportBytes {
		return "", NewBusinessError("IMPORT_LIMIT_EXCEEDED", "atomic import is limited to 1 MiB", nil)
	}
	hash := sha256.Sum256(raw)
	return hex.EncodeToString(hash[:]), nil
}

func validateImportField(field string, value any) error {
	if value == nil {
		return nil
	}
	switch field {
	case "quantity", "initial_quantity", "sort_order", "desired_quantity", "low_stock_threshold", "expiry_warning_days", "opened_warning_days", "expiry_after_opening_days":
		if _, ok := ImportInteger(value); !ok {
			return fmt.Errorf("%s must be a 32-bit integer", field)
		}
	case "reuse_existing", "is_opened", "checked", "enabled":
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("%s must be boolean", field)
		}
	case "price":
		price, ok := value.(float64)
		if !ok || price < 0 || math.IsInf(price, 0) || math.IsNaN(price) || price >= 1e10 || math.Abs(price*100-math.Round(price*100)) > 1e-5 {
			return fmt.Errorf("price must be a nonnegative decimal with at most two decimal places")
		}
	default:
		text, ok := value.(string)
		if !ok || len(text) > 8192 {
			return fmt.Errorf("%s must be bounded text", field)
		}
		switch field {
		case "product_id", "batch_id", "category_id":
			if !importUUID(text) {
				return fmt.Errorf("%s must be UUID or null", field)
			}
		case "produced_date", "expiry_date", "opened_date":
			if !validCalendarDate(text) {
				return fmt.Errorf("calendar dates must be YYYY-MM-DD")
			}
		case "created_at", "updated_at", "checked_at", "occurred_at":
			instant, err := time.Parse(time.RFC3339Nano, text)
			if err != nil || instant.Year() < 1 {
				return fmt.Errorf("%s requires an RFC3339 instant", field)
			}
		}
	}
	return nil
}

func invalidImport(entity, id, message string) error {
	return NewBusinessError("VALIDATION_FAILED", message, map[string]any{"entity": entity, "entity_id": id})
}

func importUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, char := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if char != '-' {
				return false
			}
		} else if !(char >= '0' && char <= '9' || char >= 'a' && char <= 'f') {
			return false
		}
	}
	return true
}

func ImportInteger(value any) (int64, bool) {
	switch number := value.(type) {
	case int:
		return int64(number), number >= -2147483648 && number <= 2147483647
	case int64:
		return number, number >= -2147483648 && number <= 2147483647
	case float64:
		valid := !math.IsNaN(number) && !math.IsInf(number, 0) && math.Trunc(number) == number && number >= -2147483648 && number <= 2147483647
		return int64(number), valid
	}
	return 0, false
}

func validateImportRow(entity string, row map[string]any) error {
	text := func(key string) string {
		value, _ := row[key].(string)
		return value
	}
	number := func(key string, fallback int64) int64 {
		if value, ok := ImportInteger(row[key]); ok {
			return value
		}
		return fallback
	}
	if entity == "categories" || entity == "products" || entity == "shopping_items" {
		limit := 255
		if entity == "categories" {
			limit = 120
		}
		if length := utf8.RuneCountInString(strings.TrimSpace(text("name"))); length < 1 || length > limit {
			return fmt.Errorf("name is required and too long names are not supported")
		}
	}
	for _, key := range []string{"low_stock_threshold", "desired_quantity"} {
		if row[key] != nil && number(key, 0) <= 0 {
			return fmt.Errorf("%s must be positive", key)
		}
	}
	for _, key := range []string{"expiry_warning_days", "expiry_after_opening_days"} {
		if number(key, 0) < 0 {
			return fmt.Errorf("%s must be nonnegative", key)
		}
	}
	if row["opened_warning_days"] != nil {
		return fmt.Errorf("opened_warning_days is not supported")
	}
	if entity == "categories" && row["reuse_existing"] == true && (row["color"] != nil || number("sort_order", 0) != 0) {
		return fmt.Errorf("reused category metadata must not be changed")
	}
	if entity == "product_batches" {
		if text("product_id") == "" {
			return fmt.Errorf("product_id is required")
		}
		initial, initialValid := ImportInteger(row["initial_quantity"])
		quantity, quantityValid := ImportInteger(row["quantity"])
		if !initialValid || !quantityValid || initial < 0 || quantity < 0 || quantity > initial {
			return fmt.Errorf("initial_quantity and quantity must satisfy 0 <= quantity <= initial_quantity")
		}
		status := text("status")
		if !importContains("active used_up expired discarded", status) {
			return fmt.Errorf("valid batch status is required")
		}
		if status == "active" && quantity == 0 || (status == "used_up" || status == "discarded") && quantity != 0 {
			return fmt.Errorf("status does not match quantity")
		}
		if source := text("date_source"); source != "" && !importContains("manual barcode ocr ai_draft import sync", source) {
			return fmt.Errorf("unsupported date_source")
		}
		if precision := text("date_precision"); precision != "" && !importContains("day month year unknown", precision) {
			return fmt.Errorf("unsupported date_precision")
		}
		if text("produced_date") != "" && text("expiry_date") != "" && text("produced_date") > text("expiry_date") {
			return fmt.Errorf("expiry_date precedes produced_date")
		}
	}
	if entity == "history" {
		quantity, valid := ImportInteger(row["quantity"])
		if text("product_id") == "" || text("occurred_at") == "" || !valid || (quantity == 0 && text("type") != "discard") {
			return fmt.Errorf("history requires product, occurrence time and nonzero quantity")
		}
		switch text("type") {
		case "intake", "restock":
			if quantity < 0 {
				return fmt.Errorf("intake/restock must be positive")
			}
		case "consume", "discard":
			if quantity > 0 {
				return fmt.Errorf("consume/discard must be negative")
			}
		case "adjust", "adjustment":
		default:
			return fmt.Errorf("unsupported history type")
		}
		if zone := text("source_time_zone"); zone != "" {
			if _, err := time.LoadLocation(zone); err != nil || zone == "Local" {
				return fmt.Errorf("invalid source_time_zone")
			}
		}
	}
	return nil
}

func importContains(allowed, value string) bool {
	for _, item := range strings.Fields(allowed) {
		if item == value {
			return true
		}
	}
	return false
}
