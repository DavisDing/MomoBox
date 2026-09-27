package hapostgres

import (
    "context"
    "database/sql"
    "errors"
    "fmt"
    "sort"
    "strings"
    "time"

    "github.com/momobox/backend/internal/homeassistant"
)

// AutomationRepository persists the phase-four Home Assistant linkage state.
// It deliberately owns the inventory mutation transaction so an HA decision
// cannot leave a suggestion, deduction audit, and product batch out of sync.
type AutomationRepository struct {
    db DB
}

func NewAutomationRepository(db DB) *AutomationRepository { return &AutomationRepository{db: db} }

var _ homeassistant.AutomationRepository = (*AutomationRepository)(nil)

func automationError(code homeassistant.ErrorCode, message string, cause error) error {
    return &homeassistant.BusinessError{Code: code, Message: message, Cause: cause}
}

func (r *AutomationRepository) ListConsumableGroups(ctx context.Context, familyID string) ([]homeassistant.ConsumableGroup, error) {
    if err := requireDB(r.db); err != nil { return nil, err }
    rows, err := r.db.QueryContext(ctx, `
SELECT id::text, family_id::text, name, description, created_by_user_id::text, created_at, updated_at
FROM ha_consumable_groups
WHERE family_id = $1::uuid AND deleted_at IS NULL
ORDER BY lower(name), id`, familyID)
    if err != nil { return nil, fmt.Errorf("list HA consumable groups: %w", err) }
    defer rows.Close()
    result := make([]homeassistant.ConsumableGroup, 0)
    for rows.Next() {
        var group homeassistant.ConsumableGroup
        if err := rows.Scan(&group.ID, &group.FamilyID, &group.Name, &group.Description, &group.CreatedByUserID, &group.CreatedAt, &group.UpdatedAt); err != nil { return nil, fmt.Errorf("scan HA consumable group: %w", err) }
        group.Items, err = r.listGroupItems(ctx, r.db, group.FamilyID, group.ID)
        if err != nil { return nil, err }
        result = append(result, group)
    }
    if err := rows.Err(); err != nil { return nil, fmt.Errorf("iterate HA consumable groups: %w", err) }
    return result, nil
}

func (r *AutomationRepository) SaveConsumableGroup(ctx context.Context, group homeassistant.ConsumableGroup) (homeassistant.ConsumableGroup, error) {
    if err := requireDB(r.db); err != nil { return homeassistant.ConsumableGroup{}, err }
    if err := validateGroupItems(group.Items); err != nil { return homeassistant.ConsumableGroup{}, err }
    tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
    if err != nil { return homeassistant.ConsumableGroup{}, fmt.Errorf("begin HA group save: %w", err) }
    defer rollback(tx)
    var saved homeassistant.ConsumableGroup
    err = tx.QueryRowContext(ctx, `
INSERT INTO ha_consumable_groups (id, family_id, name, description, created_by_user_id, created_at, updated_at, deleted_at)
VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2::uuid, $3, $4, $5::uuid, COALESCE(NULLIF($6, '')::timestamptz, CURRENT_TIMESTAMP), CURRENT_TIMESTAMP, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, updated_at = CURRENT_TIMESTAMP, deleted_at = NULL
WHERE ha_consumable_groups.family_id = EXCLUDED.family_id
RETURNING id::text, family_id::text, name, description, created_by_user_id::text, created_at, updated_at`,
        group.ID, group.FamilyID, strings.TrimSpace(group.Name), group.Description, group.CreatedByUserID, group.CreatedAt).Scan(
        &saved.ID, &saved.FamilyID, &saved.Name, &saved.Description, &saved.CreatedByUserID, &saved.CreatedAt, &saved.UpdatedAt)
    if err != nil { return homeassistant.ConsumableGroup{}, fmt.Errorf("save HA consumable group: %w", err) }
    if _, err := tx.ExecContext(ctx, `DELETE FROM ha_consumable_group_items WHERE family_id = $1::uuid AND group_id = $2::uuid`, saved.FamilyID, saved.ID); err != nil { return homeassistant.ConsumableGroup{}, fmt.Errorf("replace HA group items: %w", err) }
    for _, item := range group.Items {
        if _, err := tx.ExecContext(ctx, `
INSERT INTO ha_consumable_group_items (family_id, group_id, product_id, quantity, unit)
SELECT $1::uuid, $2::uuid, p.id, $4, $5
FROM products p
WHERE p.id = $3::uuid AND p.family_id = $1::uuid AND p.deleted_at IS NULL`, saved.FamilyID, saved.ID, item.ProductID, item.Quantity, string(item.Unit)); err != nil { return homeassistant.ConsumableGroup{}, fmt.Errorf("save HA group item: %w", err) }
    }
    saved.Items, err = r.listGroupItems(ctx, tx, saved.FamilyID, saved.ID)
    if err != nil { return homeassistant.ConsumableGroup{}, err }
    if len(saved.Items) != len(group.Items) { return homeassistant.ConsumableGroup{}, notFound("HA group product", sql.ErrNoRows) }
    if err := tx.Commit(); err != nil { return homeassistant.ConsumableGroup{}, fmt.Errorf("commit HA group save: %w", err) }
    return saved, nil
}

func (r *AutomationRepository) listGroupItems(ctx context.Context, q querier, familyID, groupID string) ([]homeassistant.ConsumableGroupItem, error) {
    rows, err := q.QueryContext(ctx, `
SELECT id::text, group_id::text, product_id::text, quantity, unit
FROM ha_consumable_group_items
WHERE family_id = $1::uuid AND group_id = $2::uuid
ORDER BY id`, familyID, groupID)
    if err != nil { return nil, fmt.Errorf("list HA group items: %w", err) }
    defer rows.Close()
    items := make([]homeassistant.ConsumableGroupItem, 0)
    for rows.Next() {
        var item homeassistant.ConsumableGroupItem; var unit string
        if err := rows.Scan(&item.ID, &item.GroupID, &item.ProductID, &item.Quantity, &unit); err != nil { return nil, fmt.Errorf("scan HA group item: %w", err) }
        item.Unit = homeassistant.ConsumableUnit(unit); items = append(items, item)
    }
    if err := rows.Err(); err != nil { return nil, fmt.Errorf("iterate HA group items: %w", err) }
    return items, nil
}

func (r *AutomationRepository) ListConsumableRecipes(ctx context.Context, familyID string) ([]homeassistant.ConsumableRecipe, error) {
    if err := requireDB(r.db); err != nil { return nil, err }
    rows, err := r.db.QueryContext(ctx, `
SELECT id::text, family_id::text, name, description, created_by_user_id::text, created_at, updated_at
FROM ha_consumable_recipes
WHERE family_id = $1::uuid AND deleted_at IS NULL
ORDER BY lower(name), id`, familyID)
    if err != nil { return nil, fmt.Errorf("list HA consumable recipes: %w", err) }
    defer rows.Close()
    result := make([]homeassistant.ConsumableRecipe, 0)
    for rows.Next() {
        var recipe homeassistant.ConsumableRecipe
        if err := rows.Scan(&recipe.ID, &recipe.FamilyID, &recipe.Name, &recipe.Description, &recipe.CreatedByUserID, &recipe.CreatedAt, &recipe.UpdatedAt); err != nil { return nil, fmt.Errorf("scan HA consumable recipe: %w", err) }
        recipe.Groups, err = r.listRecipeGroups(ctx, r.db, recipe.FamilyID, recipe.ID)
        if err != nil { return nil, err }
        result = append(result, recipe)
    }
    if err := rows.Err(); err != nil { return nil, fmt.Errorf("iterate HA consumable recipes: %w", err) }
    return result, nil
}

func (r *AutomationRepository) SaveConsumableRecipe(ctx context.Context, recipe homeassistant.ConsumableRecipe) (homeassistant.ConsumableRecipe, error) {
    if err := requireDB(r.db); err != nil { return homeassistant.ConsumableRecipe{}, err }
    if err := validateRecipeGroups(recipe.Groups); err != nil { return homeassistant.ConsumableRecipe{}, err }
    tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
    if err != nil { return homeassistant.ConsumableRecipe{}, fmt.Errorf("begin HA recipe save: %w", err) }
    defer rollback(tx)
    var saved homeassistant.ConsumableRecipe
    err = tx.QueryRowContext(ctx, `
INSERT INTO ha_consumable_recipes (id, family_id, name, description, created_by_user_id, created_at, updated_at, deleted_at)
VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2::uuid, $3, $4, $5::uuid, COALESCE(NULLIF($6, '')::timestamptz, CURRENT_TIMESTAMP), CURRENT_TIMESTAMP, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, updated_at = CURRENT_TIMESTAMP, deleted_at = NULL
WHERE ha_consumable_recipes.family_id = EXCLUDED.family_id
RETURNING id::text, family_id::text, name, description, created_by_user_id::text, created_at, updated_at`,
        recipe.ID, recipe.FamilyID, strings.TrimSpace(recipe.Name), recipe.Description, recipe.CreatedByUserID, recipe.CreatedAt).Scan(
        &saved.ID, &saved.FamilyID, &saved.Name, &saved.Description, &saved.CreatedByUserID, &saved.CreatedAt, &saved.UpdatedAt)
    if err != nil { return homeassistant.ConsumableRecipe{}, fmt.Errorf("save HA consumable recipe: %w", err) }
    if _, err := tx.ExecContext(ctx, `DELETE FROM ha_consumable_recipe_groups WHERE family_id = $1::uuid AND recipe_id = $2::uuid`, saved.FamilyID, saved.ID); err != nil { return homeassistant.ConsumableRecipe{}, fmt.Errorf("replace HA recipe groups: %w", err) }
    for _, item := range recipe.Groups {
        if _, err := tx.ExecContext(ctx, `
INSERT INTO ha_consumable_recipe_groups (family_id, recipe_id, group_id, quantity, unit)
SELECT $1::uuid, $2::uuid, g.id, $4, $5
FROM ha_consumable_groups g
WHERE g.id = $3::uuid AND g.family_id = $1::uuid AND g.deleted_at IS NULL`, saved.FamilyID, saved.ID, item.GroupID, item.Quantity, string(item.Unit)); err != nil { return homeassistant.ConsumableRecipe{}, fmt.Errorf("save HA recipe group: %w", err) }
    }
    saved.Groups, err = r.listRecipeGroups(ctx, tx, saved.FamilyID, saved.ID)
    if err != nil { return homeassistant.ConsumableRecipe{}, err }
    if len(saved.Groups) != len(recipe.Groups) { return homeassistant.ConsumableRecipe{}, notFound("HA consumable group", sql.ErrNoRows) }
    if err := tx.Commit(); err != nil { return homeassistant.ConsumableRecipe{}, fmt.Errorf("commit HA recipe save: %w", err) }
    return saved, nil
}

func (r *AutomationRepository) listRecipeGroups(ctx context.Context, q querier, familyID, recipeID string) ([]homeassistant.ConsumableRecipeGroup, error) {
    rows, err := q.QueryContext(ctx, `
SELECT id::text, recipe_id::text, group_id::text, quantity, unit
FROM ha_consumable_recipe_groups
WHERE family_id = $1::uuid AND recipe_id = $2::uuid
ORDER BY id`, familyID, recipeID)
    if err != nil { return nil, fmt.Errorf("list HA recipe groups: %w", err) }
    defer rows.Close()
    result := make([]homeassistant.ConsumableRecipeGroup, 0)
    for rows.Next() {
        var item homeassistant.ConsumableRecipeGroup; var unit string
        if err := rows.Scan(&item.ID, &item.RecipeID, &item.GroupID, &item.Quantity, &unit); err != nil { return nil, fmt.Errorf("scan HA recipe group: %w", err) }
        item.Unit = homeassistant.ConsumableUnit(unit); result = append(result, item)
    }
    if err := rows.Err(); err != nil { return nil, fmt.Errorf("iterate HA recipe groups: %w", err) }
    return result, nil
}

func (r *AutomationRepository) ListLinkageRules(ctx context.Context, familyID string) ([]homeassistant.LinkageRule, error) {
    if err := requireDB(r.db); err != nil { return nil, err }
    rows, err := r.db.QueryContext(ctx, ruleSelect+` WHERE r.family_id = $1::uuid AND r.deleted_at IS NULL ORDER BY lower(r.name), r.id`, familyID)
    if err != nil { return nil, fmt.Errorf("list HA linkage rules: %w", err) }
    defer rows.Close()
    result := make([]homeassistant.LinkageRule, 0)
    for rows.Next() { value, scanErr := scanRule(rows); if scanErr != nil { return nil, fmt.Errorf("scan HA linkage rule: %w", scanErr) }; result = append(result, value) }
    if err := rows.Err(); err != nil { return nil, fmt.Errorf("iterate HA linkage rules: %w", err) }
    return result, nil
}

const ruleSelect = `
SELECT r.id::text, r.family_id::text, r.name, i.id::text, e.entity_id, r.appliance_domain,
       r.start_state, r.complete_state, r.recipe_id::text, r.enabled, r.requires_confirmation,
       r.created_by_user_id::text, r.created_at, r.updated_at
FROM ha_linkage_rules r
JOIN ha_integrations i ON i.id = r.integration_id AND i.family_id = r.family_id
JOIN ha_entities e ON e.id = r.entity_id AND e.family_id = r.family_id
`

func scanRule(row scanner) (homeassistant.LinkageRule, error) {
    var value homeassistant.LinkageRule
    var start, complete string
    err := row.Scan(&value.ID, &value.FamilyID, &value.Name, &value.IntegrationID, &value.EntityID, &value.ApplianceDomain, &start, &complete, &value.RecipeID, &value.Enabled, &value.RequiresConfirmation, &value.CreatedByUserID, &value.CreatedAt, &value.UpdatedAt)
    value.StartState, value.CompleteState = start, complete
    return value, err
}

func (r *AutomationRepository) SaveLinkageRule(ctx context.Context, rule homeassistant.LinkageRule) (homeassistant.LinkageRule, error) {
	if err := requireDB(r.db); err != nil {
		return homeassistant.LinkageRule{}, err
	}
	if strings.TrimSpace(rule.FamilyID) == "" {
		return homeassistant.LinkageRule{}, automationError(homeassistant.CodeInvalidArgument, "family_id is required", nil)
	}
	start, err := homeassistant.NormalizeHAState(rule.StartState)
	if err != nil {
		return homeassistant.LinkageRule{}, automationError(homeassistant.CodeInvalidArgument, "start_state is invalid", err)
	}
	complete, err := homeassistant.NormalizeHAState(rule.CompleteState)
	if err != nil {
		return homeassistant.LinkageRule{}, automationError(homeassistant.CodeInvalidArgument, "complete_state is invalid", err)
	}
	if start == complete {
		return homeassistant.LinkageRule{}, automationError(homeassistant.CodeInvalidArgument, "start_state and complete_state must differ", nil)
	}
	if strings.TrimSpace(rule.Name) == "" || strings.TrimSpace(rule.IntegrationID) == "" || strings.TrimSpace(rule.EntityID) == "" || strings.TrimSpace(rule.ApplianceDomain) == "" || strings.TrimSpace(rule.RecipeID) == "" {
		return homeassistant.LinkageRule{}, automationError(homeassistant.CodeInvalidArgument, "linkage rule references are required", nil)
	}
	if !rule.RequiresConfirmation {
		return homeassistant.LinkageRule{}, automationError(homeassistant.CodeInvalidArgument, "requires_confirmation must remain true", nil)
	}

	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return homeassistant.LinkageRule{}, fmt.Errorf("begin HA rule save: %w", err)
	}
	defer rollback(tx)

	// Resolve all external references under the requested family before writing.
	// This prevents a valid UUID from another family being attached accidentally.
	var entityRowID string
	var entityFamilyID string
	if err := tx.QueryRowContext(ctx, `
SELECT e.id::text, e.family_id::text
FROM ha_entities e
JOIN ha_integrations i ON i.id = e.integration_id AND i.family_id = e.family_id
WHERE e.entity_id = $1
  AND i.id = $2::uuid
  AND e.family_id = $3::uuid
  AND i.family_id = $3::uuid
  AND e.deleted_at IS NULL
  AND i.deleted_at IS NULL`, strings.TrimSpace(rule.EntityID), rule.IntegrationID, rule.FamilyID).Scan(&entityRowID, &entityFamilyID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return homeassistant.LinkageRule{}, notFound("HA rule integration or entity", err)
		}
		return homeassistant.LinkageRule{}, fmt.Errorf("resolve HA rule entity: %w", err)
	}
	if entityFamilyID != rule.FamilyID {
		return homeassistant.LinkageRule{}, automationError(homeassistant.CodeForbidden, "entity is outside the current family", nil)
	}
	var recipeFamilyID string
	if err := tx.QueryRowContext(ctx, `
SELECT family_id::text
FROM ha_consumable_recipes
WHERE id = $1::uuid AND family_id = $2::uuid AND deleted_at IS NULL`, rule.RecipeID, rule.FamilyID).Scan(&recipeFamilyID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return homeassistant.LinkageRule{}, notFound("HA consumable recipe", err)
		}
		return homeassistant.LinkageRule{}, fmt.Errorf("resolve HA rule recipe: %w", err)
	}
	if recipeFamilyID != rule.FamilyID {
		return homeassistant.LinkageRule{}, automationError(homeassistant.CodeForbidden, "recipe is outside the current family", nil)
	}

	var savedID string
	if rule.ID != "" {
		var existingFamily string
		err = tx.QueryRowContext(ctx, `SELECT family_id::text FROM ha_linkage_rules WHERE id = $1::uuid`, rule.ID).Scan(&existingFamily)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return homeassistant.LinkageRule{}, fmt.Errorf("check HA linkage rule family: %w", err)
		}
		if err == nil && existingFamily != rule.FamilyID {
			return homeassistant.LinkageRule{}, automationError(homeassistant.CodeForbidden, "rule is outside the current family", nil)
		}
		if errors.Is(err, sql.ErrNoRows) {
			return homeassistant.LinkageRule{}, notFound("HA linkage rule", err)
		}
		savedID = rule.ID
	} else {
		err = tx.QueryRowContext(ctx, `SELECT gen_random_uuid()::text`).Scan(&savedID)
		if err != nil {
			return homeassistant.LinkageRule{}, fmt.Errorf("generate HA linkage rule ID: %w", err)
		}
	}

	const upsertRule = `
INSERT INTO ha_linkage_rules (
    id, family_id, name, integration_id, entity_id, appliance_domain,
    start_state, complete_state, recipe_id, enabled, requires_confirmation,
    created_by_user_id, created_at, updated_at, deleted_at
) VALUES (
    $1::uuid, $2::uuid, $3, $4::uuid, $5::uuid, $6, $7, $8, $9::uuid,
    $10, TRUE, $11::uuid, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, NULL
)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    integration_id = EXCLUDED.integration_id,
    entity_id = EXCLUDED.entity_id,
    appliance_domain = EXCLUDED.appliance_domain,
    start_state = EXCLUDED.start_state,
    complete_state = EXCLUDED.complete_state,
    recipe_id = EXCLUDED.recipe_id,
    enabled = EXCLUDED.enabled,
    requires_confirmation = TRUE,
    updated_at = CURRENT_TIMESTAMP,
    deleted_at = NULL
WHERE ha_linkage_rules.family_id = EXCLUDED.family_id
RETURNING id::text`
	if err := tx.QueryRowContext(ctx, upsertRule,
		savedID, rule.FamilyID, strings.TrimSpace(rule.Name), rule.IntegrationID,
		entityRowID, strings.TrimSpace(rule.ApplianceDomain), start, complete,
		rule.RecipeID, rule.Enabled, rule.CreatedByUserID,
	).Scan(&savedID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return homeassistant.LinkageRule{}, automationError(homeassistant.CodeForbidden, "rule is outside the current family", err)
		}
		return homeassistant.LinkageRule{}, fmt.Errorf("save HA linkage rule: %w", err)
	}

	var saved homeassistant.LinkageRule
	if err := tx.QueryRowContext(ctx, ruleSelect+` WHERE r.id = $1::uuid AND r.family_id = $2::uuid AND r.deleted_at IS NULL`, savedID, rule.FamilyID).Scan(
		&saved.ID, &saved.FamilyID, &saved.Name, &saved.IntegrationID, &saved.EntityID,
		&saved.ApplianceDomain, &saved.StartState, &saved.CompleteState, &saved.RecipeID,
		&saved.Enabled, &saved.RequiresConfirmation, &saved.CreatedByUserID,
		&saved.CreatedAt, &saved.UpdatedAt,
	); err != nil {
		return homeassistant.LinkageRule{}, fmt.Errorf("read saved HA linkage rule: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return homeassistant.LinkageRule{}, fmt.Errorf("commit HA rule save: %w", err)
	}
	return saved, nil
}

func (r *AutomationRepository) ListLinkageSuggestions(ctx context.Context, familyID string, status homeassistant.LinkageSuggestionStatus) ([]homeassistant.LinkageSuggestion, error) {
    if err := requireDB(r.db); err != nil { return nil, err }
    query := suggestionSelect + ` WHERE s.family_id=$1::uuid`; args := []any{familyID}
    if status != "" { query += ` AND s.status=$2`; args = append(args, string(status)) }
    query += ` ORDER BY s.created_at DESC, s.id`
    rows, err := r.db.QueryContext(ctx, query, args...); if err != nil { return nil, fmt.Errorf("list HA linkage suggestions: %w", err) }; defer rows.Close()
    result := make([]homeassistant.LinkageSuggestion, 0)
    for rows.Next() { value, scanErr := scanSuggestion(rows); if scanErr != nil { return nil, fmt.Errorf("scan HA linkage suggestion: %w", scanErr) }; value.PurchaseSuggestions, scanErr = r.listPurchaseSuggestions(ctx, r.db, value.FamilyID, value.ID); if scanErr != nil { return nil, scanErr }; result = append(result, value) }
    if err := rows.Err(); err != nil { return nil, fmt.Errorf("iterate HA linkage suggestions: %w", err) }
    return result, nil
}

const suggestionSelect = `
SELECT s.id::text, s.family_id::text, s.rule_id::text, s.recipe_id::text, s.appliance_run_id,
       s.status, s.requires_confirmation, s.created_at, s.resolved_at, COALESCE(s.resolved_by_user_id::text, '')
FROM ha_linkage_suggestions s`

func scanSuggestion(row scanner) (homeassistant.LinkageSuggestion, error) {
    var value homeassistant.LinkageSuggestion; var status string
    err := row.Scan(&value.ID, &value.FamilyID, &value.RuleID, &value.RecipeID, &value.ApplianceRunID, &status, &value.RequiresConfirmation, &value.CreatedAt, &value.ResolvedAt, &value.ResolvedBy)
    value.Status = homeassistant.LinkageSuggestionStatus(status); return value, err
}

func (r *AutomationRepository) listPurchaseSuggestions(ctx context.Context, q querier, familyID, suggestionID string) ([]homeassistant.PurchaseSuggestion, error) {
    rows, err := q.QueryContext(ctx, `SELECT p.product_id::text, pr.name, p.quantity, p.unit FROM ha_linkage_purchase_suggestions p JOIN products pr ON pr.id=p.product_id AND pr.family_id=p.family_id WHERE p.family_id=$1::uuid AND p.suggestion_id=$2::uuid ORDER BY p.product_id`, familyID, suggestionID); if err != nil { return nil, fmt.Errorf("list HA purchase suggestions: %w", err) }; defer rows.Close()
    result := make([]homeassistant.PurchaseSuggestion, 0)
    for rows.Next() { var value homeassistant.PurchaseSuggestion; var unit string; if err := rows.Scan(&value.ProductID, &value.ProductName, &value.Quantity, &unit); err != nil { return nil, fmt.Errorf("scan HA purchase suggestion: %w", err) }; value.Unit=homeassistant.ConsumableUnit(unit); result=append(result,value) }
    return result, rows.Err()
}

func (r *AutomationRepository) ProcessEvent(ctx context.Context, familyID string, event homeassistant.HAEvent, now time.Time) (homeassistant.EventProcessResult, error) {
	if err := requireDB(r.db); err != nil {
		return homeassistant.EventProcessResult{}, err
	}
	normalized, err := homeassistant.NormalizeHAEvent(event)
	if err != nil {
		return homeassistant.EventProcessResult{}, automationError(homeassistant.CodeInvalidArgument, err.Error(), err)
	}
	event = normalized
	if event.OccurredAt.IsZero() {
		return homeassistant.EventProcessResult{}, automationError(homeassistant.CodeInvalidArgument, "occurred_at is required", nil)
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}

	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return homeassistant.EventProcessResult{}, fmt.Errorf("begin HA event: %w", err)
	}
	defer rollback(tx)

	var rule homeassistant.LinkageRule
	err = tx.QueryRowContext(ctx, ruleSelect+` WHERE r.family_id = $1::uuid AND i.id = $2::uuid AND e.entity_id = $3 AND r.appliance_domain = $4 AND r.enabled AND r.deleted_at IS NULL FOR UPDATE`, familyID, event.IntegrationID, event.EntityID, event.Domain).Scan(
		&rule.ID, &rule.FamilyID, &rule.Name, &rule.IntegrationID, &rule.EntityID,
		&rule.ApplianceDomain, &rule.StartState, &rule.CompleteState, &rule.RecipeID,
		&rule.Enabled, &rule.RequiresConfirmation, &rule.CreatedByUserID,
		&rule.CreatedAt, &rule.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return homeassistant.EventProcessResult{}, notFound("enabled HA linkage rule", err)
	}
	if err != nil {
		return homeassistant.EventProcessResult{}, fmt.Errorf("find HA linkage rule: %w", err)
	}
	if event.State != rule.StartState && event.State != rule.CompleteState {
		if err := tx.Commit(); err != nil {
			return homeassistant.EventProcessResult{}, fmt.Errorf("commit ignored HA event: %w", err)
		}
		return homeassistant.EventProcessResult{}, nil
	}

	var run homeassistant.ApplianceRun
	var startedAt, completedAt *time.Time
	err = tx.QueryRowContext(ctx, `
SELECT id::text, family_id::text, rule_id::text, appliance_run_id,
       integration_id::text, entity_id::text, domain, status,
       started_at, completed_at, created_at, updated_at
FROM ha_appliance_runs
WHERE family_id = $1::uuid AND rule_id = $2::uuid AND appliance_run_id = $3
FOR UPDATE`, familyID, rule.ID, event.ApplianceRunID).Scan(
		&run.ID, &run.FamilyID, &run.RuleID, &run.ApplianceRunID,
		&run.IntegrationID, &run.EntityID, &run.Domain, &run.Status,
		&startedAt, &completedAt, &run.CreatedAt, &run.UpdatedAt,
	)
	exists := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return homeassistant.EventProcessResult{}, fmt.Errorf("read HA appliance run: %w", err)
	}
	if exists {
		run.StartedAt = startedAt
		run.CompletedAt = completedAt
	}
	result := homeassistant.EventProcessResult{Run: &run}

	if event.State == rule.StartState {
		if exists {
			result.Duplicate = true
			result.AuditID, err = insertLinkageAudit(ctx, tx, familyID, rule.ID, event.ApplianceRunID, "event_duplicate", "", map[string]any{"state": event.State}, now)
			if err != nil {
				return result, err
			}
			if err := tx.Commit(); err != nil {
				return result, fmt.Errorf("commit duplicate HA start event: %w", err)
			}
			return result, nil
		}

		if err := tx.QueryRowContext(ctx, `
INSERT INTO ha_appliance_runs (
    family_id, rule_id, appliance_run_id, integration_id, entity_id, domain,
    status, started_at, created_at, updated_at
) VALUES (
    $1::uuid, $2::uuid, $3, $4::uuid,
    (SELECT e.id FROM ha_entities e WHERE e.family_id = $1::uuid AND e.integration_id = $4::uuid AND e.entity_id = $5 AND e.deleted_at IS NULL),
    $6, 'running', $7, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
)
RETURNING id::text, created_at, updated_at`, familyID, rule.ID, event.ApplianceRunID, event.IntegrationID, event.EntityID, event.Domain, event.OccurredAt).Scan(&run.ID, &run.CreatedAt, &run.UpdatedAt); err != nil {
			return result, fmt.Errorf("create HA appliance run: %w", err)
		}
		run.FamilyID = familyID
		run.RuleID = rule.ID
		run.ApplianceRunID = event.ApplianceRunID
		run.IntegrationID = event.IntegrationID
		run.EntityID = event.EntityID
		run.Domain = event.Domain
		run.Status = "running"
		run.StartedAt = &event.OccurredAt
		result.Run = &run
	} else {
		if !exists {
			return homeassistant.EventProcessResult{}, automationError(homeassistant.CodeInvalidArgument, "completed HA event requires a matching running appliance run", nil)
		}
		if run.Status != "running" {
			result.Duplicate = true
			result.Suggestion, err = r.findSuggestion(ctx, tx, familyID, rule.ID, event.ApplianceRunID)
			if err != nil {
				return result, err
			}
			result.AuditID, err = insertLinkageAudit(ctx, tx, familyID, rule.ID, event.ApplianceRunID, "event_duplicate", resultSuggestionID(result.Suggestion), map[string]any{"state": event.State, "run_status": run.Status}, now)
			if err != nil {
				return result, err
			}
			if err := tx.Commit(); err != nil {
				return result, fmt.Errorf("commit duplicate HA completion event: %w", err)
			}
			return result, nil
		}
		if _, err := tx.ExecContext(ctx, `
UPDATE ha_appliance_runs
SET status = 'completed', completed_at = $4, updated_at = CURRENT_TIMESTAMP
WHERE family_id = $1::uuid AND rule_id = $2::uuid AND appliance_run_id = $3`, familyID, rule.ID, event.ApplianceRunID, event.OccurredAt); err != nil {
			return result, fmt.Errorf("complete HA appliance run: %w", err)
		}
		run.Status = "completed"
		run.CompletedAt = &event.OccurredAt
		result.Run = &run
		result.Suggestion, result.Duplicate, err = r.createSuggestion(ctx, tx, familyID, rule, event.ApplianceRunID, now)
		if err != nil {
			return result, err
		}
	}

	result.AuditID, err = insertLinkageAudit(ctx, tx, familyID, rule.ID, event.ApplianceRunID, "event_processed", resultSuggestionID(result.Suggestion), map[string]any{"state": event.State, "duplicate": result.Duplicate}, now)
	if err != nil {
		return result, err
	}
	if err := tx.Commit(); err != nil {
		return result, fmt.Errorf("commit HA event: %w", err)
	}
	return result, nil
}

func (r *AutomationRepository) findSuggestion(ctx context.Context, q querier, familyID, ruleID, runID string) (*homeassistant.LinkageSuggestion, error) {
	var value homeassistant.LinkageSuggestion
	var status string
	err := q.QueryRowContext(ctx, suggestionSelect+` WHERE s.family_id = $1::uuid AND s.rule_id = $2::uuid AND s.appliance_run_id = $3`, familyID, ruleID, runID).Scan(
		&value.ID, &value.FamilyID, &value.RuleID, &value.RecipeID, &value.ApplianceRunID,
		&status, &value.RequiresConfirmation, &value.CreatedAt, &value.ResolvedAt, &value.ResolvedBy,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read HA linkage suggestion: %w", err)
	}
	value.Status = homeassistant.LinkageSuggestionStatus(status)
	value.PurchaseSuggestions, err = r.listPurchaseSuggestions(ctx, q, familyID, value.ID)
	if err != nil {
		return nil, err
	}
	return &value, nil
}

func resultSuggestionID(value *homeassistant.LinkageSuggestion) string { if value == nil { return "" }; return value.ID }

func (r *AutomationRepository) createSuggestion(ctx context.Context, tx *sql.Tx, familyID string, rule homeassistant.LinkageRule, runID string, now time.Time) (*homeassistant.LinkageSuggestion, bool, error) {
    var value homeassistant.LinkageSuggestion
    err := tx.QueryRowContext(ctx, suggestionSelect+` WHERE s.family_id=$1::uuid AND s.rule_id=$2::uuid AND s.appliance_run_id=$3 FOR UPDATE`, familyID, rule.ID, runID).Scan(&value.ID,&value.FamilyID,&value.RuleID,&value.RecipeID,&value.ApplianceRunID,&value.Status,&value.RequiresConfirmation,&value.CreatedAt,&value.ResolvedAt,&value.ResolvedBy)
    if err == nil { value.PurchaseSuggestions, err = r.listPurchaseSuggestions(ctx,tx,familyID,value.ID); return &value,true,err }
    if !errors.Is(err,sql.ErrNoRows) { return nil,false,fmt.Errorf("read HA linkage suggestion: %w",err) }
    purchases, err := r.calculatePurchaseSuggestions(ctx, tx, familyID, rule.RecipeID, now); if err != nil { return nil,false,err }
    status := homeassistant.SuggestionPending; if len(purchases)>0 { status=homeassistant.SuggestionInsufficientStock }
    err = tx.QueryRowContext(ctx, `INSERT INTO ha_linkage_suggestions (family_id,rule_id,recipe_id,appliance_run_id,status,requires_confirmation,created_at) VALUES ($1::uuid,$2::uuid,$3::uuid,$4,$5,TRUE,$6) RETURNING id::text, family_id::text, rule_id::text, recipe_id::text, appliance_run_id, status, requires_confirmation, created_at, resolved_at, COALESCE(resolved_by_user_id::text,'')`, familyID,rule.ID,rule.RecipeID,runID,string(status),now).Scan(&value.ID,&value.FamilyID,&value.RuleID,&value.RecipeID,&value.ApplianceRunID,&value.Status,&value.RequiresConfirmation,&value.CreatedAt,&value.ResolvedAt,&value.ResolvedBy)
    if err != nil { return nil,false,fmt.Errorf("create HA linkage suggestion: %w",err) }
    value.PurchaseSuggestions=purchases
    for _, p := range purchases { if _,err:=tx.ExecContext(ctx,`INSERT INTO ha_linkage_purchase_suggestions (family_id,suggestion_id,product_id,quantity,unit) VALUES ($1::uuid,$2::uuid,$3::uuid,$4,$5)`,familyID,value.ID,p.ProductID,p.Quantity,string(p.Unit));err!=nil{return nil,false,fmt.Errorf("create HA purchase suggestion: %w",err)} }
    return &value,false,nil
}

func (r *AutomationRepository) calculatePurchaseSuggestions(ctx context.Context, q querier, familyID, recipeID string, now time.Time) ([]homeassistant.PurchaseSuggestion, error) {
    rows, err := q.QueryContext(ctx, `SELECT gi.product_id::text, p.name, (rg.quantity * gi.quantity), gi.unit FROM ha_consumable_recipe_groups rg JOIN ha_consumable_group_items gi ON gi.group_id=rg.group_id AND gi.family_id=rg.family_id JOIN products p ON p.id=gi.product_id AND p.family_id=gi.family_id WHERE rg.family_id=$1::uuid AND rg.recipe_id=$2::uuid AND p.deleted_at IS NULL ORDER BY gi.product_id`,familyID,recipeID); if err!=nil{return nil,fmt.Errorf("calculate HA consumption: %w",err)}; defer rows.Close()
    type required struct { name string; quantity int; unit homeassistant.ConsumableUnit }
    requiredByProduct:=map[string]required{}
    for rows.Next(){var id,name,unit string;var qty int;if err:=rows.Scan(&id,&name,&qty,&unit);err!=nil{return nil,fmt.Errorf("scan HA consumption: %w",err)}; value,ok:=requiredByProduct[id]; if ok && value.unit!=homeassistant.ConsumableUnit(unit){return nil,automationError(homeassistant.CodeInvalidArgument,"a product is used with incompatible consumable units",nil)}; value.name=name;value.quantity+=qty;value.unit=homeassistant.ConsumableUnit(unit);requiredByProduct[id]=value}
    if err:=rows.Err();err!=nil{return nil,err}
    ids:=make([]string,0,len(requiredByProduct));for id:=range requiredByProduct{ids=append(ids,id)};sort.Strings(ids)
    result:=make([]homeassistant.PurchaseSuggestion,0)
    date:=now.UTC().Format("2006-01-02")
    for _,id:=range ids{value:=requiredByProduct[id];var stock int;if err:=q.QueryRowContext(ctx,`SELECT COALESCE(SUM(quantity),0) FROM product_batches WHERE family_id=$1::uuid AND product_id=$2::uuid AND deleted_at IS NULL AND status='active' AND quantity>0 AND (expiry_date IS NULL OR expiry_date >= $3::date)`,familyID,id,date).Scan(&stock);err!=nil{return nil,fmt.Errorf("read HA stock: %w",err)};if stock<value.quantity{result=append(result,homeassistant.PurchaseSuggestion{ProductID:id,ProductName:value.name,Quantity:value.quantity-stock,Unit:value.unit})}}
    return result,nil
}

func (r *AutomationRepository) markSuggestionInsufficient(ctx context.Context, tx *sql.Tx, value homeassistant.LinkageSuggestion, purchases []homeassistant.PurchaseSuggestion, now time.Time, decision string) (homeassistant.LinkageSuggestion, error) {
	if _, err := tx.ExecContext(ctx, `
UPDATE ha_linkage_suggestions
SET status = 'insufficient_stock', resolved_at = NULL, resolved_by_user_id = NULL
WHERE family_id = $1::uuid AND id = $2::uuid`, value.FamilyID, value.ID); err != nil {
		return value, fmt.Errorf("mark HA suggestion insufficient: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM ha_linkage_purchase_suggestions WHERE family_id = $1::uuid AND suggestion_id = $2::uuid`, value.FamilyID, value.ID); err != nil {
		return value, fmt.Errorf("replace HA purchase suggestions: %w", err)
	}
	for _, purchase := range purchases {
		if _, err := tx.ExecContext(ctx, `
INSERT INTO ha_linkage_purchase_suggestions (family_id, suggestion_id, product_id, quantity, unit)
VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5)`, value.FamilyID, value.ID, purchase.ProductID, purchase.Quantity, string(purchase.Unit)); err != nil {
			return value, fmt.Errorf("write HA purchase suggestion: %w", err)
		}
	}
	value.Status = homeassistant.SuggestionInsufficientStock
	value.PurchaseSuggestions = purchases
	if _, err := insertLinkageAudit(ctx, tx, value.FamilyID, value.RuleID, value.ApplianceRunID, "suggestion_insufficient_stock", value.ID, map[string]any{"decision": decision}, now); err != nil {
		return value, err
	}
	if err := tx.Commit(); err != nil {
		return value, fmt.Errorf("commit insufficient HA suggestion: %w", err)
	}
	return value, nil
}

func (r *AutomationRepository) ResolveLinkageSuggestion(ctx context.Context, familyID, suggestionID string, decision homeassistant.SuggestionDecision, actorID string, now time.Time) (homeassistant.LinkageSuggestion, error) {
	if err := requireDB(r.db); err != nil {
		return homeassistant.LinkageSuggestion{}, err
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}
	if decision != homeassistant.DecisionConfirm && decision != homeassistant.DecisionIgnore {
		return homeassistant.LinkageSuggestion{}, automationError(homeassistant.CodeInvalidArgument, "decision must be confirm or ignore", nil)
	}

	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return homeassistant.LinkageSuggestion{}, fmt.Errorf("begin HA suggestion resolution: %w", err)
	}
	defer rollback(tx)

	var value homeassistant.LinkageSuggestion
	var status string
	err = tx.QueryRowContext(ctx, suggestionSelect+` WHERE s.family_id = $1::uuid AND s.id = $2::uuid FOR UPDATE`, familyID, suggestionID).Scan(
		&value.ID, &value.FamilyID, &value.RuleID, &value.RecipeID, &value.ApplianceRunID,
		&status, &value.RequiresConfirmation, &value.CreatedAt, &value.ResolvedAt, &value.ResolvedBy,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return homeassistant.LinkageSuggestion{}, notFound("HA linkage suggestion", err)
	}
	if err != nil {
		return homeassistant.LinkageSuggestion{}, fmt.Errorf("read HA suggestion: %w", err)
	}
	value.Status = homeassistant.LinkageSuggestionStatus(status)
	value.PurchaseSuggestions, err = r.listPurchaseSuggestions(ctx, tx, familyID, value.ID)
	if err != nil {
		return value, err
	}

	if decision == homeassistant.DecisionIgnore {
		if value.Status != homeassistant.SuggestionPending && value.Status != homeassistant.SuggestionInsufficientStock {
			return value, automationError(homeassistant.CodeInvalidArgument, "suggestion is already resolved", nil)
		}
		if _, err := tx.ExecContext(ctx, `
UPDATE ha_linkage_suggestions
SET status = 'ignored', resolved_at = $3, resolved_by_user_id = $4::uuid
WHERE family_id = $1::uuid AND id = $2::uuid`, familyID, value.ID, now, actorID); err != nil {
			return value, fmt.Errorf("ignore HA suggestion: %w", err)
		}
		value.Status = homeassistant.SuggestionIgnored
		value.ResolvedAt = &now
		value.ResolvedBy = actorID
		value.PurchaseSuggestions = nil
		if _, err := insertLinkageAudit(ctx, tx, familyID, value.RuleID, value.ApplianceRunID, "suggestion_ignored", value.ID, map[string]any{"decision": "ignore"}, now); err != nil {
			return value, err
		}
		if err := tx.Commit(); err != nil {
			return value, fmt.Errorf("commit ignored HA suggestion: %w", err)
		}
		return value, nil
	}

	if value.Status == homeassistant.SuggestionDeducted {
		if err := tx.Commit(); err != nil {
			return value, fmt.Errorf("commit already deducted HA suggestion: %w", err)
		}
		return value, nil
	}
	if value.Status == homeassistant.SuggestionIgnored {
		return value, automationError(homeassistant.CodeInvalidArgument, "ignored suggestion cannot be confirmed", nil)
	}

	// Re-check stock before taking locks. If stock is already short, refresh the
	// purchase suggestions in this same transaction and do not touch batches.
	purchases, err := r.calculatePurchaseSuggestions(ctx, tx, familyID, value.RecipeID, now)
	if err != nil {
		return value, err
	}
	if len(purchases) > 0 {
		return r.markSuggestionInsufficient(ctx, tx, value, purchases, now, "confirm")
	}

	rowsByProduct, err := r.lockRequiredBatches(ctx, tx, familyID, value.RecipeID, now)
	if err != nil {
		var businessErr *homeassistant.BusinessError
		if errors.As(err, &businessErr) && businessErr.Code == homeassistant.CodeInvalidArgument {
			// A concurrent inventory change can make the pre-check stale. The
			// transaction has not mutated inventory yet, so refresh atomically.
			purchases, refreshErr := r.calculatePurchaseSuggestions(ctx, tx, familyID, value.RecipeID, now)
			if refreshErr != nil {
				return value, refreshErr
			}
			return r.markSuggestionInsufficient(ctx, tx, value, purchases, now, "confirm_after_recheck")
		}
		return value, err
	}

	operationID, err := r.newOperationID(ctx, tx)
	if err != nil {
		return value, err
	}
	for _, productID := range sortedBatchProducts(rowsByProduct) {
		remaining := rowsByProduct[productID].required
		for _, batch := range rowsByProduct[productID].batches {
			if remaining == 0 {
				break
			}
			take := batch.quantity
			if take > remaining {
				take = remaining
			}
			var after int
			var afterVersion int64
			if err := tx.QueryRowContext(ctx, `
UPDATE product_batches
SET quantity = quantity - $3,
    status = CASE WHEN quantity - $3 = 0 THEN 'used_up' ELSE 'active' END,
    version = version + 1,
    updated_at = CURRENT_TIMESTAMP
WHERE family_id = $1::uuid AND id = $2::uuid AND quantity >= $3
RETURNING quantity, version`, familyID, batch.id, take).Scan(&after, &afterVersion); err != nil {
				return value, fmt.Errorf("deduct HA inventory batch: %w", err)
			}
			if _, err := tx.ExecContext(ctx, `
INSERT INTO ha_linkage_deductions (
    family_id, suggestion_id, product_id, batch_id, quantity,
    before_quantity, after_quantity, before_version, after_version, operation_id
) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5, $6, $7, $8, $9, $10::uuid)`, familyID, value.ID, productID, batch.id, take, batch.quantity, after, batch.version, afterVersion, operationID); err != nil {
				return value, fmt.Errorf("record HA deduction: %w", err)
			}
			if _, err := tx.ExecContext(ctx, `
INSERT INTO consumption_records (
    family_id, batch_id, product_id, record_type, quantity_change,
    reason, operation_id, idempotency_key, created_by_user_id, device_id, created_at
) VALUES ($1::uuid, $2::uuid, $3::uuid, 'consume', $4,
          'home_assistant_linkage', $5::uuid, $6, $7::uuid, NULL, $8)`, familyID, batch.id, productID, -take, operationID, "ha-linkage:"+value.ID+":"+batch.id, actorID, now); err != nil {
				return value, fmt.Errorf("record HA consumption: %w", err)
			}
			remaining -= take
		}
	}

	if _, err := tx.ExecContext(ctx, `DELETE FROM ha_linkage_purchase_suggestions WHERE family_id = $1::uuid AND suggestion_id = $2::uuid`, familyID, value.ID); err != nil {
		return value, fmt.Errorf("clear HA purchase suggestions: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
UPDATE ha_linkage_suggestions
SET status = 'deducted', resolved_at = $3, resolved_by_user_id = $4::uuid
WHERE family_id = $1::uuid AND id = $2::uuid`, familyID, value.ID, now, actorID); err != nil {
		return value, fmt.Errorf("resolve HA suggestion: %w", err)
	}
	value.Status = homeassistant.SuggestionDeducted
	value.PurchaseSuggestions = nil
	value.ResolvedAt = &now
	value.ResolvedBy = actorID
	if _, err := insertLinkageAudit(ctx, tx, familyID, value.RuleID, value.ApplianceRunID, "suggestion_deducted", value.ID, map[string]any{"decision": "confirm", "operation_id": operationID}, now); err != nil {
		return value, err
	}
	if err := tx.Commit(); err != nil {
		return value, fmt.Errorf("commit HA suggestion resolution: %w", err)
	}
	return value, nil
}

type lockedBatch struct{id string; quantity int; version int64}
type requiredBatches struct{required int;batches []lockedBatch}
func (r *AutomationRepository) lockRequiredBatches(ctx context.Context,tx *sql.Tx,familyID,recipeID string,now time.Time)(map[string]requiredBatches,error){
    rows,err:=tx.QueryContext(ctx,`SELECT gi.product_id::text,(rg.quantity*gi.quantity) FROM ha_consumable_recipe_groups rg JOIN ha_consumable_group_items gi ON gi.group_id=rg.group_id AND gi.family_id=rg.family_id WHERE rg.family_id=$1::uuid AND rg.recipe_id=$2::uuid ORDER BY gi.product_id`,familyID,recipeID);if err!=nil{return nil,err};defer rows.Close();required:=map[string]int{};for rows.Next(){var id string;var qty int;if err:=rows.Scan(&id,&qty);err!=nil{return nil,err};required[id]+=qty};if err:=rows.Err();err!=nil{return nil,err};result:=map[string]requiredBatches{};date:=now.UTC().Format("2006-01-02");ids:=make([]string,0,len(required));for id:=range required{ids=append(ids,id)};sort.Strings(ids);for _,id:=range ids{batchRows,err:=tx.QueryContext(ctx,`SELECT id::text,quantity,version FROM product_batches WHERE family_id=$1::uuid AND product_id=$2::uuid AND deleted_at IS NULL AND status='active' AND quantity>0 AND (expiry_date IS NULL OR expiry_date >= $3::date) ORDER BY expiry_date ASC NULLS LAST,id FOR UPDATE`,familyID,id,date);if err!=nil{return nil,err};var batches []lockedBatch;total:=0;for batchRows.Next(){var b lockedBatch;if err:=batchRows.Scan(&b.id,&b.quantity,&b.version);err!=nil{batchRows.Close();return nil,err};batches=append(batches,b);total+=b.quantity};batchRows.Close();if total<required[id]{return nil,automationError(homeassistant.CodeInvalidArgument,"inventory changed and is insufficient for confirmation",nil)};result[id]=requiredBatches{required:required[id],batches:batches}};return result,nil}
func sortedBatchProducts(values map[string]requiredBatches)[]string{ids:=make([]string,0,len(values));for id:=range values{ids=append(ids,id)};sort.Strings(ids);return ids}
func (r *AutomationRepository)newOperationID(ctx context.Context,tx *sql.Tx)(string,error){var id string;if err:=tx.QueryRowContext(ctx,`SELECT gen_random_uuid()::text`).Scan(&id);err!=nil{return "",fmt.Errorf("generate HA operation ID: %w",err)};return id,nil}
func insertLinkageAudit(ctx context.Context,tx *sql.Tx,familyID,ruleID,runID,suggestionID,action string,details map[string]any,now time.Time)(string,error){payload,err:=marshalJSON(details);if err!=nil{return "",err};var id string;err=tx.QueryRowContext(ctx,`INSERT INTO ha_linkage_audit_logs (family_id,rule_id,appliance_run_id,suggestion_id,action,actor_id,details,created_at) VALUES ($1::uuid,NULLIF($2,'')::uuid,$3,NULLIF($4,'')::uuid,$5,NULL,$6::jsonb,$7) RETURNING id::text`,familyID,ruleID,runID,suggestionID,action,payload,now).Scan(&id);if err!=nil{return "",fmt.Errorf("write HA linkage audit: %w",err)};return id,nil}
func validateGroupItems(items []homeassistant.ConsumableGroupItem)error{seen:=map[string]struct{}{};for _,item:=range items{if item.Quantity<1||!item.Unit.Valid()||strings.TrimSpace(item.ProductID)==""{return automationError(homeassistant.CodeInvalidArgument,"group item is invalid",nil)};if _,ok:=seen[item.ProductID];ok{return automationError(homeassistant.CodeInvalidArgument,"a group cannot contain the same product twice",nil)};seen[item.ProductID]=struct{}{}};return nil}
func validateRecipeGroups(items []homeassistant.ConsumableRecipeGroup)error{seen:=map[string]struct{}{};for _,item:=range items{if item.Quantity<1||!item.Unit.Valid()||strings.TrimSpace(item.GroupID)==""{return automationError(homeassistant.CodeInvalidArgument,"recipe group is invalid",nil)};if _,ok:=seen[item.GroupID];ok{return automationError(homeassistant.CodeInvalidArgument,"a recipe cannot contain the same group twice",nil)};seen[item.GroupID]=struct{}{}};return nil}
