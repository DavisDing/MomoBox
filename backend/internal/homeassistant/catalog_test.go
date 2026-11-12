package homeassistant

import (
	"context"
	"testing"
	"time"
)

func TestEntityCatalogDoesNotGrantStateOrControl(t *testing.T) {
	integration := contractIntegration("family-a", "integration-a")
	entity := contractEntity("family-a", integration.ID, "light.new")
	entity.CurrentState = "on"
	now := time.Now().UTC()
	entity.LastStateAt = &now
	service, integrations, entities, permissions, _, _, client := contractService(integration, entity)
	// Deliberately include foreign rows: repository filtering is not the only guard.
	foreign := contractEntity("family-b", integration.ID, "light.foreign")
	entities.items[entityKey(integration.ID, foreign.EntityID)] = foreign
	for _, role := range []Role{RoleOwner, RoleAdmin} {
		actor := Actor{UserID: "user", FamilyID: "family-a", Role: role}
		values, err := service.ListEntityCatalog(context.Background(), actor, integration.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(values) != 1 || values[0].EntityID != entity.EntityID {
			t.Fatalf("catalog = %#v", values)
		}
		if values[0].CurrentState != nil || values[0].LastStateAt != nil {
			t.Fatalf("catalog exposed cached state: %#v", values)
		}
		listed, err := service.ListEntities(context.Background(), actor, integration.ID, false)
		if err != nil || len(listed) != 0 {
			t.Fatalf("catalog granted entity view: %#v %v", listed, err)
		}
		permissions.items[permissionKey("family-a", integration.ID, entity.EntityID, role)] = EntityPermission{
			FamilyID: "family-a", IntegrationID: integration.ID, EntityID: entity.EntityID,
			Role: role, CanView: false, CanControl: false,
		}
		if _, err := service.GetState(context.Background(), actor, integration.ID, entity.EntityID); businessCode(t, err) != CodeForbidden {
			t.Fatalf("state error = %v", err)
		}
		if _, err := service.ExecuteCommand(context.Background(), actor, integration.ID, entity.EntityID, CommandRequest{Command: CommandTurnOn, RequestID: contractRequestID}); businessCode(t, err) != CodeForbidden {
			t.Fatalf("command error = %v", err)
		}
	}
	if len(permissions.upserts) != 0 || client.stateCalls != 0 || client.executeCalls != 0 {
		t.Fatal("catalog changed grants or called HA")
	}
	if _, err := service.ListEntityCatalog(context.Background(), Actor{UserID: "user", FamilyID: "family-a", Role: RoleMember}, integration.ID); businessCode(t, err) != CodeForbidden {
		t.Fatalf("member catalog error = %v", err)
	}
	integrations.items[integration.ID] = contractIntegration("family-b", integration.ID)
	if _, err := service.ListEntityCatalog(context.Background(), Actor{UserID: "user", FamilyID: "family-a", Role: RoleOwner}, integration.ID); businessCode(t, err) != CodeNotFound {
		t.Fatalf("foreign catalog error = %v", err)
	}
}
