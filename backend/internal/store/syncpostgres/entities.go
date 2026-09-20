package syncpostgres

import (
	"fmt"
	"strings"
)

type entityColumn struct {
	name       string
	cast       string
	insertExpr string
}

type entitySpec struct {
	table          string
	columns        []entityColumn
	requiredInsert []string
}

var bootstrapEntities = []string{
	"categories",
	"products",
	"product_batches",
	"shopping_items",
	"reminder_settings",
}

var entitySpecs = map[string]entitySpec{
	"categories": {
		table: "categories",
		columns: []entityColumn{
			{name: "name", cast: "text", insertExpr: "NULLIF($3::jsonb ->> 'name', '')"},
			{name: "color", cast: "text"},
			{name: "sort_order", cast: "integer", insertExpr: "COALESCE(($3::jsonb ->> 'sort_order')::integer, 0)"},
		},
		requiredInsert: []string{"name"},
	},
	"products": {
		table: "products",
		columns: []entityColumn{
			{name: "name", cast: "text", insertExpr: "NULLIF($3::jsonb ->> 'name', '')"},
			{name: "barcode", cast: "text"},
			{name: "brand", cast: "text"},
			{name: "specification", cast: "text"},
			{name: "category_id", cast: "uuid"},
			{name: "identity_key", cast: "text"},
			{name: "notes", cast: "text"},
		},
		requiredInsert: []string{"name"},
	},
	"product_batches": {
		table: "product_batches",
		columns: []entityColumn{
			{name: "product_id", cast: "uuid"},
			{name: "produced_date", cast: "date"},
			{name: "expiry_date", cast: "date"},
			{name: "date_source", cast: "text"},
			{name: "date_precision", cast: "text"},
			{name: "unit", cast: "text", insertExpr: "COALESCE(NULLIF($3::jsonb ->> 'unit', ''), 'piece')"},
			{name: "opened_date", cast: "date"},
			{name: "expiry_after_opening_days", cast: "integer"},
			{name: "storage_location", cast: "text"},
			{name: "supplier", cast: "text"},
			{name: "price", cast: "numeric"},
		},
		requiredInsert: []string{"product_id"},
	},
	"shopping_items": {
		table: "shopping_items",
		columns: []entityColumn{
			{name: "product_id", cast: "uuid"},
			{name: "name", cast: "text", insertExpr: "NULLIF($3::jsonb ->> 'name', '')"},
			{name: "desired_quantity", cast: "integer", insertExpr: "COALESCE(($3::jsonb ->> 'desired_quantity')::integer, 1)"},
			{name: "checked", cast: "boolean", insertExpr: "COALESCE(($3::jsonb ->> 'checked')::boolean, false)"},
			{name: "checked_at", cast: "timestamptz"},
			{name: "notes", cast: "text"},
		},
		requiredInsert: []string{"name"},
	},
	"reminder_settings": {
		table: "reminder_settings",
		columns: []entityColumn{
			{name: "product_id", cast: "uuid"},
			{name: "enabled", cast: "boolean", insertExpr: "COALESCE(($3::jsonb ->> 'enabled')::boolean, true)"},
			{name: "expiry_warning_days", cast: "integer", insertExpr: "COALESCE(($3::jsonb ->> 'expiry_warning_days')::integer, 7)"},
			{name: "low_stock_threshold", cast: "integer"},
			{name: "opened_warning_days", cast: "integer"},
		},
	},
}

func buildInsertSQL(spec entitySpec) string {
	columnNames := []string{"id", "family_id"}
	insertValues := []string{"$1::uuid", "$2::uuid"}
	for _, column := range spec.columns {
		columnNames = append(columnNames, column.name)
		expression := column.insertExpr
		if expression == "" {
			expression = jsonValueExpression(column, false)
		}
		insertValues = append(insertValues, expression)
	}
	columnNames = append(columnNames, "created_by_user_id", "updated_by_device")
	insertValues = append(insertValues, "NULLIF($6, '')::uuid", "NULLIF($4, '')::uuid")
	return fmt.Sprintf(`
INSERT INTO %s (%s)
VALUES (%s)
RETURNING version, to_jsonb(%s) - 'family_id', deleted_at`,
		spec.table,
		strings.Join(columnNames, ", "),
		strings.Join(insertValues, ", "),
		spec.table,
	)
}

func buildUpdateSQL(spec entitySpec) string {
	updates := make([]string, 0, len(spec.columns)+4)
	for _, column := range spec.columns {
		expression := strings.ReplaceAll(jsonValueExpression(column, true), "__TABLE__", spec.table)
		updates = append(updates, fmt.Sprintf("%s = %s", column.name, expression))
	}
	updates = append(updates,
		"updated_by_device = NULLIF($4, '')::uuid",
		"version = "+spec.table+".version + 1",
		"deleted_at = NULL",
		"updated_at = CURRENT_TIMESTAMP",
	)
	return fmt.Sprintf(`
UPDATE %s
SET %s
WHERE family_id = $2::uuid
  AND id = $1::uuid
  AND version = $5
RETURNING version, to_jsonb(%s) - 'family_id', deleted_at`,
		spec.table,
		strings.Join(updates, ",\n    "),
		spec.table,
	)
}

func jsonValueExpression(column entityColumn, preserveWhenMissing bool) string {
	value := fmt.Sprintf("NULLIF($3::jsonb ->> '%s', '')", column.name)
	if column.cast != "text" {
		value += "::" + column.cast
	}
	if !preserveWhenMissing {
		return value
	}
	return fmt.Sprintf("CASE WHEN $3::jsonb ? '%s' THEN %s ELSE %s.%s END", column.name, value, tableForColumn(column.name), column.name)
}

// tableForColumn is replaced by buildUpdateSQL before execution. Keeping the
// marker separate makes every identifier originate from the hard-coded specs.
func tableForColumn(string) string { return "__TABLE__" }

func validateRequiredPayload(spec entitySpec, payload map[string]any, inserting bool) error {
	if !inserting {
		return nil
	}
	for _, field := range spec.requiredInsert {
		value, exists := payload[field]
		if !exists || strings.TrimSpace(fmt.Sprint(value)) == "" || value == nil {
			return fmt.Errorf("%s is required when creating %s", field, spec.table)
		}
	}
	return nil
}

func containsProtectedBatchQuantity(payload map[string]any) bool {
	for _, field := range []string{"quantity", "current_quantity", "quantity_change", "initial_quantity", "status"} {
		if _, exists := payload[field]; exists {
			return true
		}
	}
	return false
}
