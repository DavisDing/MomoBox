package syncpostgres

import (
	"encoding/json"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/momobox/backend/internal/homeassistant"
	"github.com/momobox/backend/internal/store/hapostgres"
	syncdomain "github.com/momobox/backend/internal/sync"
)

func TestPostgresMalformedChangesDoNotPoisonBatchAndReplayRejections(t *testing.T) {
	for _, malformed := range []struct {
		name, id string
		payload  map[string]any
	}{
		{"temporary ID", "tmp-1", map[string]any{"name": "bad"}},
		{"invalid hex", "z0000000-0000-4000-8000-000000000001", map[string]any{"name": "bad"}},
		{"invalid number", importBatch, map[string]any{"name": "bad", "low_stock_threshold": "not-an-integer"}},
		{"constraint violation", importBatch, map[string]any{"name": "bad", "low_stock_threshold": -1}},
	} {
		t.Run(malformed.name, func(t *testing.T) {
			f := newImportPostgresFixture(t)
			request := syncdomain.PushRequest{DeviceID: importDevice, Changes: []syncdomain.SyncChange{
				{ChangeID: importPlan, Operation: syncdomain.OperationEntityUpsert, Entity: "products", EntityID: malformed.id, Payload: malformed.payload, IdempotencyKey: "audit-malformed-change-1"},
				{ChangeID: importCategory, Operation: syncdomain.OperationEntityUpsert, Entity: "products", EntityID: importProduct, Payload: map[string]any{"name": "valid"}, IdempotencyKey: "audit-valid-change-2"},
			}}
			first, err := f.service.Push(f.ctx, request)
			if err != nil || len(first.Rejected) != 1 || first.Rejected[0].Code != "VALIDATION_FAILED" || len(first.Accepted) != 1 {
				t.Fatalf("batch poisoned: %#v %v", first, err)
			}
			replay, err := f.service.Push(f.ctx, request)
			if err != nil || len(replay.Replayed) != 2 || replay.Replayed[0].OriginalStatus != syncdomain.PushStatusRejected || f.count(t, "products") != 1 || f.count(t, "change_log") != 1 {
				t.Fatalf("bad replay/partial mutation: %#v %v", replay, err)
			}
		})
	}
}

func TestPostgresHADiscoveryRestoresIdentityAndPermissions(t *testing.T) {
	f := newImportPostgresFixture(t)
	f.exec(t, `INSERT INTO ha_integrations(id,family_id,name,base_url,access_token_ciphertext,key_version,created_by_user_id) VALUES($1::uuid,$2::uuid,'HA','http://ha.local','ciphertext','1',$3::uuid)`, importPlan, importFamily, importUser)
	repo := hapostgres.NewEntityRepository(f.db)
	entity := homeassistant.HAEntity{ID: importProduct, EntityID: "light.kitchen", Domain: "light", Name: "Kitchen", Capabilities: []string{}, IsVisible: true, IsControllable: true, CreatedAt: time.Now(), UpdatedAt: time.Now()}
	if err := repo.ReplaceForIntegration(f.ctx, importFamily, importPlan, []homeassistant.HAEntity{entity}); err != nil {
		t.Fatal(err)
	}
	permissions := hapostgres.NewPermissionRepository(f.db)
	grant := homeassistant.EntityPermission{FamilyID: importFamily, IntegrationID: importPlan, EntityID: entity.EntityID, Role: homeassistant.RoleMember, CanView: true, CanControl: true, AllowedCommands: []homeassistant.Command{homeassistant.CommandTurnOn}}
	if err := permissions.Upsert(f.ctx, grant); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := repo.ReplaceForIntegration(f.ctx, importFamily, importPlan, nil); err != nil {
			t.Fatal(err)
		}
		if _, err := repo.Get(f.ctx, importFamily, importPlan, entity.EntityID); err == nil {
			t.Fatal("missing entity still exposed")
		}
		entity.ID = importBatch
		if err := repo.ReplaceForIntegration(f.ctx, importFamily, importPlan, []homeassistant.HAEntity{entity}); err != nil {
			t.Fatal(err)
		}
		stored, err := repo.Get(f.ctx, importFamily, importPlan, entity.EntityID)
		if err != nil || stored.ID != importProduct {
			t.Fatalf("identity changed: %#v %v", stored, err)
		}
		got, err := permissions.Get(f.ctx, importFamily, importPlan, entity.EntityID, homeassistant.RoleMember)
		if err != nil || !reflect.DeepEqual(got, grant) {
			t.Fatalf("grant lost: %#v %v", got, err)
		}
	}
}

func TestPostgresConflictResolutionReceiptsReplayWithoutDuplicateWrites(t *testing.T) {
	for _, action := range []syncdomain.ConflictAction{syncdomain.ConflictActionKeepRemote, syncdomain.ConflictActionKeepLocal, syncdomain.ConflictActionManualMerge, syncdomain.ConflictActionDefer} {
		t.Run(string(action), func(t *testing.T) {
			f := newImportPostgresFixture(t)
			f.exec(t, `INSERT INTO products(id,family_id,name) VALUES($1::uuid,$2::uuid,'server')`, importProduct, importFamily)
			pushed, err := f.service.Push(f.ctx, syncdomain.PushRequest{DeviceID: importDevice, Changes: []syncdomain.SyncChange{{ChangeID: importPlan, Operation: syncdomain.OperationEntityUpsert, Entity: "products", EntityID: importProduct, Payload: map[string]any{"name": "client"}, IdempotencyKey: "audit-create-conflict"}}})
			if err != nil || len(pushed.Conflicts) != 1 {
				t.Fatalf("create conflict: %#v %v", pushed, err)
			}
			request := syncdomain.ConflictResolveRequest{DeviceID: importDevice, ConflictID: pushed.Conflicts[0].ConflictID, Action: action, ExpectedVersion: 1, IdempotencyKey: "audit-resolve-conflict"}
			if action == syncdomain.ConflictActionManualMerge {
				request.MergedPayload = map[string]any{"name": "merged"}
			}
			first, err := f.service.ResolveConflict(f.ctx, request)
			if err != nil {
				t.Fatal(err)
			}
			var wg sync.WaitGroup
			for i := 0; i < 2; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					again, err := f.service.ResolveConflict(f.ctx, request)
					a, _ := json.Marshal(first)
					b, _ := json.Marshal(again)
					if err != nil || string(a) != string(b) {
						t.Errorf("retry changed receipt: %s vs %s %v", a, b, err)
					}
				}()
			}
			wg.Wait()
			var audits int
			if err := f.db.QueryRowContext(f.ctx, `SELECT count(*) FROM sync_audit_log WHERE action IN ('conflict_resolved','conflict_deferred')`).Scan(&audits); err != nil || audits != 1 {
				t.Fatalf("duplicate resolution audit: %d %v", audits, err)
			}
			changed := request
			changed.ExpectedVersion = 2
			_, err = f.service.ResolveConflict(f.ctx, changed)
			var business *syncdomain.BusinessError
			if !errors.As(err, &business) || business.Code != "IDEMPOTENCY_KEY_REUSE" {
				t.Fatalf("key reuse accepted: %v", err)
			}
			if action != syncdomain.ConflictActionDefer {
				changed = request
				changed.IdempotencyKey = "audit-different-resolve-key"
				_, err = f.service.ResolveConflict(f.ctx, changed)
				if !errors.As(err, &business) || business.Code != "CONFLICT_ALREADY_RESOLVED" {
					t.Fatalf("closed conflict accepted: %v", err)
				}
			}
			want := 0
			if action == syncdomain.ConflictActionKeepLocal || action == syncdomain.ConflictActionManualMerge {
				want = 1
			}
			if f.count(t, "change_log") != want {
				t.Fatal("resolution duplicated change log")
			}
		})
	}
}
