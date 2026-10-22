package syncpostgres

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/momobox/backend/internal/store/common"
	syncdomain "github.com/momobox/backend/internal/sync"
)

var _ syncdomain.InitialImportRepository = (*Repository)(nil)

// Every import operation rechecks token scope against current database state.
// Locks prevent membership removal, device revocation or family switching from
// racing an accepted baseline. JWT role and client queue counts are not proof.
func importIdentity(ctx context.Context, tx *sql.Tx, actor syncdomain.DeviceScope, write bool) (string, error) {
	var zone, role string
	err := tx.QueryRowContext(ctx, `
SELECT f.time_zone, fm.role FROM sync_devices d
JOIN users u ON u.id=d.user_id AND u.deleted_at IS NULL AND u.current_family_id=d.family_id
JOIN families f ON f.id=d.family_id AND f.deleted_at IS NULL
JOIN family_members fm ON fm.family_id=d.family_id AND fm.user_id=d.user_id AND fm.deleted_at IS NULL
WHERE d.id=$1::uuid AND d.user_id=$2::uuid AND d.family_id=$3::uuid
  AND d.revoked_at IS NULL AND d.deleted_at IS NULL
FOR SHARE OF d,u,f,fm`, actor.DeviceID, actor.UserID, actor.FamilyID).Scan(&zone, &role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", syncdomain.NewBusinessError("FORBIDDEN", "current family membership and device are required", nil)
	}
	if err != nil {
		return "", err
	}
	if write && role != "owner" && role != "admin" {
		return "", syncdomain.NewBusinessError("FORBIDDEN", "only an owner or admin can import", nil)
	}
	if _, err := time.LoadLocation(zone); err != nil {
		return "", fmt.Errorf("invalid stored family time zone: %w", err)
	}
	return zone, nil
}

func (r *Repository) ImportCapabilities(ctx context.Context, actor syncdomain.DeviceScope) (syncdomain.ImportCapabilities, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return syncdomain.ImportCapabilities{}, err
	}
	defer tx.Rollback()
	zone, err := importIdentity(ctx, tx, actor, false)
	if err != nil {
		return syncdomain.ImportCapabilities{}, err
	}
	if err := tx.Commit(); err != nil {
		return syncdomain.ImportCapabilities{}, err
	}
	return syncdomain.ImportCapabilities{
		ImportFormatVersion: 1,
		AtomicImport: true,
		MaxRecords: syncdomain.MaxImportRecords,
		MaxRequestBytes: syncdomain.MaxImportBytes,
		HistoryArchive: true,
		CalendarDates: true,
		FamilyTimeZone: zone,
	}, nil
}

func importLock(ctx context.Context, tx *sql.Tx, family string) error {
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "momobox:import:"+family)
	return err
}

func readImportPlan(ctx context.Context, tx *sql.Tx, actor syncdomain.DeviceScope, id string) (syncdomain.ImportReceipt, syncdomain.ImportRequest, error) {
	var user string
	var receiptRaw, manifestRaw []byte
	err := tx.QueryRowContext(ctx, `
SELECT user_id::text, receipt, manifest FROM sync_import_plans
WHERE family_id=$1::uuid AND import_id=$2::uuid FOR UPDATE`, actor.FamilyID, id).Scan(&user, &receiptRaw, &manifestRaw)
	if errors.Is(err, sql.ErrNoRows) {
		return syncdomain.ImportReceipt{}, syncdomain.ImportRequest{}, syncdomain.ErrNotFound
	}
	if err != nil {
		return syncdomain.ImportReceipt{}, syncdomain.ImportRequest{}, err
	}
	if user != actor.UserID {
		return syncdomain.ImportReceipt{}, syncdomain.ImportRequest{}, syncdomain.NewBusinessError("FORBIDDEN", "import belongs to a different account", nil)
	}
	var receipt syncdomain.ImportReceipt
	var manifest syncdomain.ImportRequest
	if err = json.Unmarshal(receiptRaw, &receipt); err != nil {
		return receipt, manifest, err
	}
	err = json.Unmarshal(manifestRaw, &manifest)
	return receipt, manifest, err
}

func (r *Repository) PreflightImport(ctx context.Context, actor syncdomain.DeviceScope, request syncdomain.ImportRequest, fingerprint string) (syncdomain.ImportReceipt, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return syncdomain.ImportReceipt{}, err
	}
	defer tx.Rollback()
	zone, err := importIdentity(ctx, tx, actor, true)
	if err != nil {
		return syncdomain.ImportReceipt{}, err
	}
	if err = importLock(ctx, tx, actor.FamilyID); err != nil {
		return syncdomain.ImportReceipt{}, err
	}
	previous, _, err := readImportPlan(ctx, tx, actor, request.ImportID)
	if err != nil && !errors.Is(err, syncdomain.ErrNotFound) {
		return syncdomain.ImportReceipt{}, err
	}
	found := err == nil
	if found && previous.Fingerprint != fingerprint {
		return syncdomain.ImportReceipt{}, syncdomain.NewBusinessError("IMPORT_ID_REUSED", "import ID is already bound to a different manifest", nil)
	}
	if found && previous.Status == "completed" {
		if err := tx.Commit(); err != nil {
			return syncdomain.ImportReceipt{}, err
		}
		return previous, nil
	}
	receipt := syncdomain.ImportReceipt{
		ImportID: request.ImportID,
		Status: "blocked",
		Fingerprint: fingerprint,
		Counts: map[string]int{},
		Blockers: []syncdomain.ImportBlocker{},
		FamilyTimeZone: zone,
	}
	for entity, rows := range request.Entities() {
		receipt.Counts[entity] = len(rows)
	}
	if err = tx.QueryRowContext(ctx, currentCursorSQL, actor.FamilyID).Scan(&receipt.ServerCursor); err != nil {
		return receipt, err
	}
	if err = tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(cursor),0) FROM imported_stock_history WHERE family_id=$1::uuid`, actor.FamilyID).Scan(&receipt.HistoryCursor); err != nil {
		return receipt, err
	}
	receipt.Blockers, err = validateImportTargets(ctx, tx, actor, request)
	if err != nil {
		return receipt, err
	}
	if len(receipt.Blockers) != 0 {
		// Rechecking a previously prepared plan can revoke it, never leave a
		// stale confirmation capability behind a ready=false response.
		_, err = tx.ExecContext(ctx, `
DELETE FROM sync_import_plans
WHERE family_id=$1::uuid AND import_id=$2::uuid AND state='prepared'`, actor.FamilyID, request.ImportID)
		if err != nil {
			return receipt, err
		}
		if err = tx.Commit(); err != nil {
			return receipt, err
		}
		return receipt, nil
	}
	receipt.Status = "prepared"
	receipt.Ready = true
	if found {
		receipt.Checkpoint = previous.Checkpoint
	} else {
		if err = tx.QueryRowContext(ctx, `SELECT gen_random_uuid()::text`).Scan(&receipt.Checkpoint); err != nil {
			return receipt, err
		}
	}
	raw, err := json.Marshal(request)
	if err != nil {
		return receipt, err
	}
	receiptRaw, err := json.Marshal(receipt)
	if err != nil {
		return receipt, err
	}
	_, err = tx.ExecContext(ctx, `
INSERT INTO sync_import_plans(family_id,import_id,user_id,device_id,local_workspace_id,fingerprint,checkpoint,state,manifest,receipt)
VALUES($1::uuid,$2::uuid,$3::uuid,$4::uuid,$5,$6,$7::uuid,'prepared',$8::jsonb,$9::jsonb)
ON CONFLICT(family_id,import_id) DO UPDATE SET receipt=EXCLUDED.receipt`, actor.FamilyID, request.ImportID, actor.UserID, actor.DeviceID, request.LocalWorkspaceID, fingerprint, receipt.Checkpoint, raw, receiptRaw)
	if err != nil {
		return receipt, err
	}
	if err = tx.Commit(); err != nil {
		return receipt, err
	}
	return receipt, nil
}

func validateImportTargets(ctx context.Context, tx *sql.Tx, actor syncdomain.DeviceScope, request syncdomain.ImportRequest) ([]syncdomain.ImportBlocker, error) {
	blockers := []syncdomain.ImportBlocker{}
	add := func(code, entity, id, message string) {
		blockers = append(blockers, syncdomain.ImportBlocker{Code: code, Entity: entity, EntityID: id, Message: message})
	}
	if request.UnsettledOutboxCount != 0 {
		add("UNSETTLED_LOCAL_OUTBOX", "", "", "local outbox must be settled before import")
	}
	var bootstrapReady, unsettled bool
	err := tx.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM sync_bootstrap_checkpoints
WHERE family_id=$1::uuid AND device_id=$2::uuid AND local_workspace_id=$3
  AND state='confirmed' AND mode IN ('join_and_merge','create_new_family'))`, actor.FamilyID, actor.DeviceID, request.LocalWorkspaceID).Scan(&bootstrapReady)
	if err != nil {
		return nil, err
	}
	if !bootstrapReady {
		add("BOOTSTRAP_NOT_CONFIRMED", "", "", "confirm the current workspace bootstrap before import")
	}
	err = tx.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM conflict_records WHERE family_id=$1::uuid AND status='open')
OR EXISTS(SELECT 1 FROM sync_idempotency
WHERE family_id=$1::uuid AND device_id=$2::uuid AND status='processing'
  AND (expires_at IS NULL OR expires_at>CURRENT_TIMESTAMP))`, actor.FamilyID, actor.DeviceID).Scan(&unsettled)
	if err != nil {
		return nil, err
	}
	if unsettled {
		add("UNSETTLED_REMOTE_SYNC", "", "", "remote sync conflicts or unresolved receipts require review")
	}
	entities := request.Entities()
	for _, entity := range append(append([]string{}, bootstrapEntities...), "history") {
		table := entitySpecs[entity].table
		if entity == "history" {
			table = "imported_stock_history"
		}
		for _, row := range entities[entity] {
			id := rowString(row, "id")
			query := fmt.Sprintf(`SELECT EXISTS(SELECT 1 FROM %s WHERE id=$1::uuid)`, table)
			args := []any{id}
			if entity == "history" {
				query = `SELECT EXISTS(SELECT 1 FROM imported_stock_history WHERE family_id=$2::uuid AND id=$1::uuid)`
				args = append(args, actor.FamilyID)
			}
			var exists bool
			if err := tx.QueryRowContext(ctx, query, args...).Scan(&exists); err != nil {
				return nil, err
			}
			if entity == "categories" && row["reuse_existing"] == true {
				var matches bool
				err := tx.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM categories
WHERE family_id=$1::uuid AND id=$2::uuid AND name=$3 AND deleted_at IS NULL)`, actor.FamilyID, id, rowString(row, "name")).Scan(&matches)
				if err != nil {
					return nil, err
				}
				if !matches {
					add("CATEGORY_REUSE_MISMATCH", entity, id, "selected category is unavailable or has changed")
				}
				continue
			}
			if exists {
				add("UUID_OVERLAP", entity, id, "UUID already exists; review instead of overwriting")
			}
			if entity == "categories" {
				var named bool
				err := tx.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM categories
WHERE family_id=$1::uuid AND lower(name)=lower($2) AND deleted_at IS NULL)`, actor.FamilyID, rowString(row, "name")).Scan(&named)
				if err != nil {
					return nil, err
				}
				if named {
					add("CATEGORY_NAME_OVERLAP", entity, id, "category name already exists; select and confirm its UUID")
				}
			}
			for _, relation := range []struct{ field, target string }{{"category_id", "categories"}, {"product_id", "products"}} {
				if entity == "history" {
					continue
				}
				targetID := rowString(row, relation.field)
				if targetID == "" {
					continue
				}
				inPlan := false
				for _, target := range entities[relation.target] {
					if rowString(target, "id") == targetID {
						inPlan = true
						break
					}
				}
				if inPlan {
					continue
				}
				var active bool
				query := fmt.Sprintf(`SELECT EXISTS(SELECT 1 FROM %s WHERE family_id=$1::uuid AND id=$2::uuid AND deleted_at IS NULL)`, entitySpecs[relation.target].table)
				if err := tx.QueryRowContext(ctx, query, actor.FamilyID, targetID).Scan(&active); err != nil {
					return nil, err
				}
				if !active {
					add("MISSING_DEPENDENCY", entity, id, relation.field+" must reference an active object in this family or manifest")
				}
			}
		}
	}
	// Catch within-manifest category names and reminder scopes before writes.
	// Database uniqueness remains the final race guard.
	names := map[string]bool{}
	for _, row := range request.Categories {
		name := strings.ToLower(rowString(row, "name"))
		if names[name] {
			add("CATEGORY_NAME_OVERLAP", "categories", rowString(row, "id"), "manifest contains repeated category names")
		}
		names[name] = true
	}
	reminders := map[string]bool{}
	for _, row := range request.ReminderSettings {
		product := rowString(row, "product_id")
		var exists bool
		err := tx.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM reminder_settings
WHERE family_id=$1::uuid AND product_id IS NOT DISTINCT FROM NULLIF($2,'')::uuid
  AND deleted_at IS NULL)`, actor.FamilyID, product).Scan(&exists)
		if err != nil {
			return nil, err
		}
		if exists || reminders[product] {
			add("REMINDER_SCOPE_OVERLAP", "reminder_settings", rowString(row, "id"), "reminder policy already exists for this scope")
		}
		reminders[product] = true
	}
	return blockers, nil
}

func rowString(row map[string]any, key string) string {
	value, _ := row[key].(string)
	return value
}

func (r *Repository) ConfirmImport(ctx context.Context, actor syncdomain.DeviceScope, id string, request syncdomain.ImportConfirmRequest) (syncdomain.ImportReceipt, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return syncdomain.ImportReceipt{}, err
	}
	defer tx.Rollback()
	zone, err := importIdentity(ctx, tx, actor, true)
	if err != nil {
		return syncdomain.ImportReceipt{}, err
	}
	if err = importLock(ctx, tx, actor.FamilyID); err != nil {
		return syncdomain.ImportReceipt{}, err
	}
	receipt, manifest, err := readImportPlan(ctx, tx, actor, id)
	if err != nil {
		return receipt, err
	}
	if receipt.Checkpoint != request.Checkpoint || receipt.Fingerprint != request.Fingerprint {
		return receipt, syncdomain.NewBusinessError("IMPORT_CHECKPOINT_STALE", "review the frozen import again", nil)
	}
	fingerprint, err := syncdomain.ValidateImport(manifest)
	if err != nil || fingerprint != receipt.Fingerprint {
		return receipt, errors.New("stored import manifest is invalid")
	}
	if receipt.Status == "completed" {
		if err = tx.Commit(); err != nil {
			return receipt, err
		}
		return receipt, nil
	}
	// Rare bounded imports explicitly serialize their final target check with
	// ordinary writers. No change-log cursor is allocated before this lock.
	_, err = tx.ExecContext(ctx, `
LOCK TABLE categories, products, product_batches, shopping_items,
           reminder_settings, imported_stock_history
IN SHARE ROW EXCLUSIVE MODE`)
	if err != nil {
		return receipt, err
	}
	manifest.UnsettledOutboxCount = request.UnsettledOutboxCount
	blockers, err := validateImportTargets(ctx, tx, actor, manifest)
	if err != nil {
		return receipt, err
	}
	if len(blockers) != 0 {
		return receipt, syncdomain.NewBusinessError("IMPORT_BLOCKED", "import targets changed; run preflight and review again", map[string]any{"blockers": blockers})
	}
	adapter := &transactionRepository{tx: tx, familyID: actor.FamilyID, deviceID: actor.DeviceID, userID: actor.UserID}
	entities := manifest.Entities()
	for _, entity := range bootstrapEntities {
		for _, row := range entities[entity] {
			if entity == "categories" && row["reuse_existing"] == true {
				continue
			}
			payload, err := insertImportEntity(ctx, tx, actor, entity, row)
			if err != nil {
				return receipt, importWriteError(err)
			}
			change := syncdomain.ChangeLogEntry{
				ChangeID: importChangeID(id, entity, rowString(row, "id")),
				Operation: syncdomain.OperationEntityUpsert,
				Entity: entity,
				EntityID: rowString(row, "id"),
				Version: 1,
				Payload: payload,
			}
			accepted, err := adapter.AppendChange(ctx, change)
			if err != nil {
				return receipt, err
			}
			receipt.ServerCursor = accepted.Cursor
		}
	}
	for _, row := range manifest.History {
		raw, err := json.Marshal(row)
		if err != nil {
			return receipt, err
		}
		_, err = tx.ExecContext(ctx, `
INSERT INTO imported_stock_history(
    family_id,id,import_id,local_workspace_id,product_id,batch_id,type,quantity,
    note,occurred_at,source_time_zone,imported_by_user_id,imported_by_device_id)
VALUES($1::uuid,($5::jsonb->>'id')::uuid,$2::uuid,$3,
       ($5::jsonb->>'product_id')::uuid,($5::jsonb->>'batch_id')::uuid,
       $5::jsonb->>'type',($5::jsonb->>'quantity')::integer,$5::jsonb->>'note',
       ($5::jsonb->>'occurred_at')::timestamptz,$5::jsonb->>'source_time_zone',
       $4::uuid,$6::uuid)`, actor.FamilyID, id, manifest.LocalWorkspaceID, actor.UserID, raw, actor.DeviceID)
		if err != nil {
			return receipt, importWriteError(err)
		}
	}
	if err = tx.QueryRowContext(ctx, currentCursorSQL, actor.FamilyID).Scan(&receipt.ServerCursor); err != nil {
		return receipt, err
	}
	if err = tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(cursor),0) FROM imported_stock_history WHERE family_id=$1::uuid`, actor.FamilyID).Scan(&receipt.HistoryCursor); err != nil {
		return receipt, err
	}
	receipt.Status = "completed"
	receipt.Ready = false
	receipt.CompletedAt = time.Now().UTC().Format(time.RFC3339Nano)
	receipt.FamilyTimeZone = zone
	raw, err := json.Marshal(receipt)
	if err != nil {
		return receipt, err
	}
	_, err = tx.ExecContext(ctx, `
UPDATE sync_import_plans SET state='completed',receipt=$3::jsonb,completed_at=CURRENT_TIMESTAMP
WHERE family_id=$1::uuid AND import_id=$2::uuid`, actor.FamilyID, id, raw)
	if err != nil {
		return receipt, err
	}
	details := map[string]any{"fingerprint": receipt.Fingerprint, "counts": receipt.Counts}
	if err = writeSyncAuditTx(ctx, tx, actor.FamilyID, actor.DeviceID, actor.UserID, "initial_import_completed", "import_plan", id, details); err != nil {
		return receipt, err
	}
	if err = tx.Commit(); err != nil {
		return receipt, err
	}
	return receipt, nil
}

func insertImportEntity(ctx context.Context, tx *sql.Tx, actor syncdomain.DeviceScope, entity string, row map[string]any) (map[string]any, error) {
	spec := entitySpecs[entity]
	// Copy the slice so dedicated baseline columns never enter ordinary upsert.
	spec.columns = append([]entityColumn(nil), spec.columns...)
	if entity == "product_batches" {
		spec.columns = append(spec.columns,
			entityColumn{name: "initial_quantity", cast: "integer"},
			entityColumn{name: "quantity", cast: "integer"},
			entityColumn{name: "status", cast: "text"},
		)
		for index := range spec.columns {
			switch spec.columns[index].name {
			case "date_source":
				spec.columns[index].insertExpr = "COALESCE($3::jsonb ->> 'date_source', 'import')"
			case "date_precision":
				spec.columns[index].insertExpr = "COALESCE($3::jsonb ->> 'date_precision', 'day')"
			}
		}
	}
	spec.columns = append(spec.columns,
		entityColumn{name: "created_at", cast: "timestamptz", insertExpr: "COALESCE(($3::jsonb ->> 'created_at')::timestamptz, CURRENT_TIMESTAMP)"},
		entityColumn{name: "updated_at", cast: "timestamptz", insertExpr: "COALESCE(($3::jsonb ->> 'updated_at')::timestamptz, CURRENT_TIMESTAMP)"},
	)
	query := buildInsertSQL(spec)
	raw, err := json.Marshal(row)
	if err != nil {
		return nil, err
	}
	var version int64
	var payloadRaw []byte
	var deleted sql.NullTime
	err = tx.QueryRowContext(ctx, query, rowString(row, "id"), actor.FamilyID, raw, actor.DeviceID, actor.UserID).Scan(&version, &payloadRaw, &deleted)
	if err != nil {
		return nil, err
	}
	var payload map[string]any
	err = json.Unmarshal(payloadRaw, &payload)
	return payload, err
}

func importChangeID(plan, entity, id string) string {
	sum := sha256.Sum256([]byte(plan + ":" + entity + ":" + id))
	sum[6] = (sum[6] & 15) | 80
	sum[8] = (sum[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", sum[0:4], sum[4:6], sum[6:8], sum[8:10], sum[10:16])
}

func importWriteError(err error) error {
	if common.HasSQLState(err, common.SQLStateUniqueViolation) || common.HasSQLState(err, common.SQLStateForeignKeyViolation) || common.HasSQLState(err, common.SQLStateCheckViolation) {
		return syncdomain.NewBusinessError("IMPORT_BLOCKED", "import target or constraint changed; review a fresh preflight", nil)
	}
	return err
}

func (r *Repository) ImportReceipt(ctx context.Context, actor syncdomain.DeviceScope, id string) (syncdomain.ImportReceipt, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return syncdomain.ImportReceipt{}, err
	}
	defer tx.Rollback()
	if _, err = importIdentity(ctx, tx, actor, false); err != nil {
		return syncdomain.ImportReceipt{}, err
	}
	receipt, _, err := readImportPlan(ctx, tx, actor, id)
	if err != nil {
		return receipt, err
	}
	if err = tx.Commit(); err != nil {
		return receipt, err
	}
	return receipt, nil
}

func (r *Repository) ImportHistory(ctx context.Context, actor syncdomain.DeviceScope, request syncdomain.ImportHistoryRequest) (syncdomain.ImportHistoryPage, error) {
	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		return syncdomain.ImportHistoryPage{}, err
	}
	defer tx.Rollback()
	if _, err = importIdentity(ctx, tx, actor, false); err != nil {
		return syncdomain.ImportHistoryPage{}, err
	}
	var current int64
	if err = tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(cursor),0) FROM imported_stock_history WHERE family_id=$1::uuid`, actor.FamilyID).Scan(&current); err != nil {
		return syncdomain.ImportHistoryPage{}, err
	}
	if request.Until == 0 {
		request.Until = current
	}
	if request.Until > current || request.After > request.Until {
		return syncdomain.ImportHistoryPage{}, syncdomain.NewBusinessError("VALIDATION_FAILED", "history cursor exceeds the family high-watermark", nil)
	}
	rows, err := tx.QueryContext(ctx, `
SELECT cursor,to_jsonb(h)-'family_id'-'imported_by_user_id'-'imported_by_device_id'
FROM imported_stock_history h
WHERE family_id=$1::uuid AND cursor>$2 AND cursor<=$3 ORDER BY cursor LIMIT $4`, actor.FamilyID, request.After, request.Until, request.Limit+1)
	if err != nil {
		return syncdomain.ImportHistoryPage{}, err
	}
	page := syncdomain.ImportHistoryPage{Records: []map[string]any{}, NextCursor: request.After, Until: request.Until}
	for rows.Next() {
		var cursor int64
		var raw []byte
		if err = rows.Scan(&cursor, &raw); err != nil {
			rows.Close()
			return page, err
		}
		if len(page.Records) == request.Limit {
			page.HasMore = true
			break
		}
		var record map[string]any
		if err = json.Unmarshal(raw, &record); err != nil {
			rows.Close()
			return page, err
		}
		page.Records = append(page.Records, record)
		page.NextCursor = cursor
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		return page, err
	}
	if err = rows.Close(); err != nil {
		return page, err
	}
	if !page.HasMore {
		page.NextCursor = page.Until
	}
	if err = tx.Commit(); err != nil {
		return page, err
	}
	return page, nil
}
