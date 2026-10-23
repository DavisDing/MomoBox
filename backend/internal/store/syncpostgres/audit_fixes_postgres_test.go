package syncpostgres

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/homeassistant"
	"github.com/momobox/backend/internal/securetoken"
	"github.com/momobox/backend/internal/store/authpostgres"
	"github.com/momobox/backend/internal/store/hapostgres"
	syncdomain "github.com/momobox/backend/internal/sync"
	"github.com/momobox/backend/internal/syncdevice"
)

func TestPostgresOpaqueHAEncryptionVersionRoundTrip(t *testing.T) {
	f := newImportPostgresFixture(t)
	cipher, err := securetoken.NewAESGCM([]byte("01234567890123456789012345678901"))
	if err != nil {
		t.Fatal(err)
	}
	ciphertext, version, err := cipher.Encrypt(f.ctx, "protected-ha-token-123")
	if err != nil {
		t.Fatal(err)
	}
	repo := hapostgres.NewIntegrationRepository(f.db)
	integration := homeassistant.Integration{ID: importPlan, FamilyID: importFamily, Name: "Home", BaseURL: "http://ha.local:8123", KeyVersion: version, AccessTokenCiphertext: ciphertext, Status: homeassistant.IntegrationUnknown, Enabled: true, CreatedAt: time.Now(), UpdatedAt: time.Now()}
	if err := repo.Create(f.ctx, integration); err != nil {
		t.Fatal(err)
	}
	stored, err := repo.Get(f.ctx, importFamily, importPlan)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := cipher.Decrypt(f.ctx, stored.AccessTokenCiphertext, stored.KeyVersion)
	if err != nil || plaintext != "protected-ha-token-123" || stored.KeyVersion != version {
		t.Fatalf("production cipher/persistence mismatch: %q %v", stored.KeyVersion, err)
	}
}
func TestPostgresRevocationInvalidatesRefreshAndUnexpiredAccess(t *testing.T) {
	f := newImportPostgresFixture(t)
	now := time.Now().UTC()
	refresh := authpostgres.NewRefreshTokenRepository(f.db)
	original := auth.RefreshTokenRecord{ID: importPlan, UserID: importUser, FamilyID: importFamily, DeviceID: importDevice, TokenHash: "original-refresh-hash", CreatedAt: now, ExpiresAt: now.Add(time.Hour)}
	if err := refresh.Create(f.ctx, original); err != nil {
		t.Fatal(err)
	}
	stale, err := refresh.FindByHash(f.ctx, original.TokenHash)
	if err != nil {
		t.Fatal(err)
	}
	claims := auth.AccessTokenClaims{UserID: importUser, FamilyID: importFamily, DeviceID: importDevice, Role: "member", ExpiresAt: now.Add(time.Hour)}
	authorizer := authpostgres.NewAccessAuthorizer(f.db)
	current, err := authorizer.AuthorizeClaims(f.ctx, claims)
	if err != nil || current.Role != "owner" {
		t.Fatalf("JWT role did not follow current membership: %#v %v", current, err)
	}
	if err := authpostgres.NewSyncDeviceRepository(f.db).Revoke(f.ctx, importFamily, importDevice, syncdevice.DeviceTouch{SeenAt: now}); err != nil {
		t.Fatal(err)
	}
	if _, err := authorizer.AuthorizeClaims(f.ctx, claims); err == nil {
		t.Fatal("revoked device retained access")
	}
	if _, err := refresh.FindByHash(f.ctx, original.TokenHash); err == nil {
		t.Fatal("revoked device retained refresh lookup")
	}
	stale.ID = importCategory
	stale.TokenHash = "replacement-refresh-hash"
	if err := refresh.Rotate(f.ctx, original.TokenHash, stale, now); err == nil {
		t.Fatal("stale pre-revocation lookup rotated revoked device")
	}
	var active int
	if err := f.db.QueryRowContext(f.ctx, `SELECT count(*) FROM refresh_tokens WHERE device_id=$1::uuid AND revoked_at IS NULL`, importDevice).Scan(&active); err != nil || active != 0 {
		t.Fatalf("active revoked-device tokens=%d: %v", active, err)
	}
}
func TestPostgresRemovedMembershipCannotReadOrWriteSync(t *testing.T) {
	f := newImportPostgresFixture(t)
	f.exec(t, `UPDATE family_members SET deleted_at=CURRENT_TIMESTAMP WHERE family_id=$1::uuid AND user_id=$2::uuid`, importFamily, importUser)
	_, err := f.service.Pull(f.ctx, syncdomain.PullRequest{DeviceID: importDevice})
	if !errors.Is(err, syncdomain.ErrDeviceNotFound) {
		t.Fatalf("removed member pull accepted: %v", err)
	}
	_, err = f.service.Bootstrap(f.ctx, syncdomain.BootstrapRequest{DeviceID: importDevice})
	if !errors.Is(err, syncdomain.ErrDeviceNotFound) {
		t.Fatalf("removed member bootstrap accepted: %v", err)
	}
	_, err = f.service.Push(f.ctx, syncdomain.PushRequest{DeviceID: importDevice, Changes: []syncdomain.SyncChange{{ChangeID: importPlan, IdempotencyKey: "membership-removal-operation", Operation: syncdomain.OperationEntityUpsert, Entity: "products", EntityID: importProduct, Payload: map[string]any{"name": "blocked"}}}})
	if !errors.Is(err, syncdomain.ErrDeviceNotFound) || f.count(t, "products") != 0 {
		t.Fatalf("removed member mutation accepted: %v", err)
	}
}
func TestPostgresZeroDiscardIsVersionedIdempotentStateTransition(t *testing.T) {
	f := newImportPostgresFixture(t)
	f.exec(t, `INSERT INTO products(id,family_id,name) VALUES($1::uuid,$2::uuid,'Milk')`, importProduct, importFamily)
	f.exec(t, `INSERT INTO product_batches(id,family_id,product_id,initial_quantity,quantity,status) VALUES($1::uuid,$2::uuid,$3::uuid,3,0,'used_up')`, importBatch, importFamily, importProduct)
	request := syncdomain.PushRequest{DeviceID: importDevice, Changes: []syncdomain.SyncChange{{ChangeID: importPlan, IdempotencyKey: "zero-discard-stable-operation", Operation: syncdomain.OperationInventoryCommand, OperationID: importPlan, Command: "discard", Allocations: []syncdomain.InventoryAllocation{{BatchID: importBatch, Quantity: 0}}}}}
	first, err := f.service.Push(f.ctx, request)
	if err != nil || len(first.Accepted) != 1 {
		t.Fatalf("zero discard failed: %#v %v", first, err)
	}
	replay, err := f.service.Push(f.ctx, request)
	if err != nil || len(replay.Replayed) != 1 {
		t.Fatalf("zero discard replay failed: %#v %v", replay, err)
	}
	var status string
	var quantity int
	var version int64
	if err := f.db.QueryRowContext(f.ctx, `SELECT quantity,status,version FROM product_batches WHERE id=$1::uuid`, importBatch).Scan(&quantity, &status, &version); err != nil {
		t.Fatal(err)
	}
	if quantity != 0 || status != "discarded" || version != 2 || f.count(t, "consumption_records") != 1 || f.count(t, "change_log") != 1 {
		t.Fatalf("invalid state-only discard %d/%s/%d", quantity, status, version)
	}
}

func TestPostgresHALinkagePublishesEveryAllocationOnce(t *testing.T) {
	f := newImportPostgresFixture(t)
	const integrationID = "d0000000-0000-4000-8000-000000000001"
	const entityID = "d0000000-0000-4000-8000-000000000002"
	const groupID = "d0000000-0000-4000-8000-000000000003"
	const recipeID = "d0000000-0000-4000-8000-000000000004"
	const ruleID = "d0000000-0000-4000-8000-000000000005"
	const suggestionID = "d0000000-0000-4000-8000-000000000006"
	const secondBatch = "d0000000-0000-4000-8000-000000000007"
	f.exec(t, `INSERT INTO products(id,family_id,name) VALUES($1::uuid,$2::uuid,'Capsules')`, importProduct, importFamily)
	for _, id := range []string{importBatch, secondBatch} {
		f.exec(t, `INSERT INTO product_batches(id,family_id,product_id,initial_quantity,quantity,status) VALUES($1::uuid,$2::uuid,$3::uuid,2,2,'active')`, id, importFamily, importProduct)
	}
	f.exec(t, `INSERT INTO ha_integrations(id,family_id,name,base_url,access_token_ciphertext,key_version,created_by_user_id) VALUES($1::uuid,$2::uuid,'HA','http://ha.local','ciphertext','1',$3::uuid)`, integrationID, importFamily, importUser)
	f.exec(t, `INSERT INTO ha_entities(id,family_id,integration_id,entity_id,domain,name) VALUES($1::uuid,$2::uuid,$3::uuid,'switch.washer','switch','Washer')`, entityID, importFamily, integrationID)
	f.exec(t, `INSERT INTO ha_consumable_groups(id,family_id,name,created_by_user_id) VALUES($1::uuid,$2::uuid,'Capsules',$3::uuid)`, groupID, importFamily, importUser)
	f.exec(t, `INSERT INTO ha_consumable_group_items(family_id,group_id,product_id,quantity,unit) VALUES($1::uuid,$2::uuid,$3::uuid,3,'piece')`, importFamily, groupID, importProduct)
	f.exec(t, `INSERT INTO ha_consumable_recipes(id,family_id,name,created_by_user_id) VALUES($1::uuid,$2::uuid,'Standard',$3::uuid)`, recipeID, importFamily, importUser)
	f.exec(t, `INSERT INTO ha_consumable_recipe_groups(family_id,recipe_id,group_id,quantity,unit) VALUES($1::uuid,$2::uuid,$3::uuid,1,'piece')`, importFamily, recipeID, groupID)
	f.exec(t, `INSERT INTO ha_linkage_rules(id,family_id,name,integration_id,entity_id,appliance_domain,start_state,complete_state,recipe_id,created_by_user_id) VALUES($1::uuid,$2::uuid,'Washer',$3::uuid,$4::uuid,'switch','running','completed',$5::uuid,$6::uuid)`, ruleID, importFamily, integrationID, entityID, recipeID, importUser)
	f.exec(t, `INSERT INTO ha_linkage_suggestions(id,family_id,rule_id,recipe_id,appliance_run_id) VALUES($1::uuid,$2::uuid,$3::uuid,$4::uuid,'wash-once')`, suggestionID, importFamily, ruleID, recipeID)
	repo := hapostgres.NewAutomationRepository(f.db)
	for i := 0; i < 2; i++ {
		result, err := repo.ResolveLinkageSuggestion(f.ctx, importFamily, suggestionID, homeassistant.DecisionConfirm, importUser, time.Now())
		if err != nil || result.Status != homeassistant.SuggestionDeducted {
			t.Fatalf("confirm %d failed: %#v %v", i, result, err)
		}
	}
	page, err := f.service.Pull(f.ctx, syncdomain.PullRequest{DeviceID: importSecondDevice})
	if err != nil || len(page.Changes) != 1 || f.count(t, "consumption_records") != 2 {
		t.Fatalf("HA deduction not published once: %#v %v", page, err)
	}
	allocations, ok := page.Changes[0].Payload["allocations"].([]any)
	if !ok || len(allocations) != 2 {
		t.Fatalf("HA sync omitted allocation: %#v", page.Changes[0].Payload)
	}
	var auditAction string
	if err := f.db.QueryRowContext(f.ctx, `SELECT action FROM ha_linkage_audit_logs WHERE suggestion_id=$1::uuid`, suggestionID).Scan(&auditAction); err != nil || auditAction != "suggestion_deducted" {
		t.Fatalf("HA audit action/suggestion identity mismatch: %q %v", auditAction, err)
	}
}

type auditExternalHAExecutor struct {
	db    *sql.DB
	calls int
}

func (e *auditExternalHAExecutor) ExecuteHomeAssistantCommand(ctx context.Context, _, _ string, _ syncdomain.SyncChange) (syncdomain.HomeAssistantCommandResult, error) {
	// With a one-connection pool this would time out if sync held its sql.Tx.
	var value int
	if err := e.db.QueryRowContext(ctx, `SELECT 1`).Scan(&value); err != nil {
		return syncdomain.HomeAssistantCommandResult{}, err
	}
	e.calls++
	return syncdomain.HomeAssistantCommandResult{Payload: map[string]any{"accepted": true}}, nil
}
func TestPostgresHAExternalExecutionUsesNoHeldConnectionAndKeepsOperationIdentity(t *testing.T) {
	f := newImportPostgresFixture(t)
	f.db.SetMaxOpenConns(1)
	executor := &auditExternalHAExecutor{db: f.db}
	service := syncdomain.NewService(New(f.db, WithHomeAssistantExecutor(executor)))
	request := syncdomain.PushRequest{DeviceID: importDevice, Changes: []syncdomain.SyncChange{{ChangeID: importPlan, IdempotencyKey: "external-ha-operation-identity", Operation: syncdomain.OperationHomeAssistantCommand, IntegrationID: importCategory, EntityID: "light.kitchen", Command: "turn_on"}}}
	for i := 0; i < 2; i++ {
		response, err := service.Push(f.ctx, request)
		if err != nil || len(response.Accepted)+len(response.Replayed) != 1 {
			t.Fatalf("external sync failed: %#v %v", response, err)
		}
	}
	var operation string
	if err := f.db.QueryRowContext(f.ctx, `SELECT operation FROM sync_idempotency WHERE family_id=$1::uuid AND device_id=$2::uuid`, importFamily, importDevice).Scan(&operation); err != nil || operation != "home_assistant_command" || executor.calls != 1 {
		t.Fatalf("external receipt metadata/replay mismatch: %q calls=%d %v", operation, executor.calls, err)
	}
}
