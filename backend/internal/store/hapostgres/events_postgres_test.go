package hapostgres

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/momobox/backend/internal/homeassistant"
	"github.com/momobox/backend/internal/platform"
)

func TestHAEventPersistencePostgres(t *testing.T) {
	dsn := strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL"))
	if dsn == "" {
		t.Skip("MOMO_TEST_DATABASE_URL unset")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid explicit PostgreSQL test configuration")
	}
	admin := stdlib.OpenDB(*config)
	defer admin.Close()
	var entropy [8]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	database := "momobox_ha_events_" + hex.EncodeToString(entropy[:])
	if _, err := admin.ExecContext(ctx, "CREATE DATABASE "+database); err != nil {
		t.Fatalf("create isolated test database: %v", err)
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := admin.ExecContext(cleanup, "DROP DATABASE "+database+" WITH (FORCE)"); err != nil {
			t.Errorf("remove isolated test database: %v", err)
		}
	}()
	scoped := config.Copy()
	scoped.Database = database
	runner := platform.SQLMigrationRunner{
		DatabaseURL: "isolated-test-database", Directory: "../../../migrations",
		Open: func(string) (platform.DB, error) { return platform.SQLDB{DB: stdlib.OpenDB(*scoped)}, nil },
	}
	if err := runner.Run(ctx); err != nil {
		t.Fatal(err)
	}
	db := stdlib.OpenDB(*scoped)
	defer db.Close()

	const (
		userID        = "10000000-0000-4000-8000-000000000001"
		familyID      = "20000000-0000-4000-8000-000000000001"
		integrationID = "30000000-0000-4000-8000-000000000001"
		productID     = "40000000-0000-4000-8000-000000000001"
	)
	if _, err := db.ExecContext(ctx, `
INSERT INTO users (id, email, password_hash, nickname) VALUES
    ('10000000-0000-4000-8000-000000000001', 'ha@example.invalid', 'test-only', 'owner');
INSERT INTO families (id, name, time_zone, created_by_user_id) VALUES
    ('20000000-0000-4000-8000-000000000001', 'test family', 'Asia/Shanghai', '10000000-0000-4000-8000-000000000001');
INSERT INTO family_members (family_id, user_id, role) VALUES
    ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'owner');
INSERT INTO ha_integrations (id, family_id, name, base_url, access_token_ciphertext, created_by_user_id) VALUES
    ('30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001',
     'HA', 'http://ha.test:8123', 'fixture', '10000000-0000-4000-8000-000000000001');
INSERT INTO ha_entities (family_id, integration_id, entity_id, domain, name) VALUES
    ('20000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 'sensor.washer', 'sensor', 'Washer'),
    ('20000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 'binary_sensor.door', 'binary_sensor', 'Door'),
    ('20000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 'binary_sensor.other', 'binary_sensor', 'Other');
INSERT INTO products (id, family_id, name) VALUES
    ('40000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'Laundry capsules');
INSERT INTO product_batches (family_id, product_id, quantity, initial_quantity) VALUES
    ('20000000-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000001', 3, 3);
`); err != nil {
		t.Fatal(err)
	}
	automation := NewAutomationRepository(db)
	group, err := automation.SaveConsumableGroup(ctx, homeassistant.ConsumableGroup{
		FamilyID: familyID, CreatedByUserID: userID, Name: "Capsules", CreatedAt: time.Now(),
		Items: []homeassistant.ConsumableGroupItem{{ProductID: productID, Quantity: 1, Unit: homeassistant.UnitCapsule}},
	})
	if err != nil {
		t.Fatal(err)
	}
	recipe, err := automation.SaveConsumableRecipe(ctx, homeassistant.ConsumableRecipe{
		FamilyID: familyID, CreatedByUserID: userID, Name: "Normal wash", CreatedAt: time.Now(),
		Groups: []homeassistant.ConsumableRecipeGroup{{GroupID: group.ID, Quantity: 1, Unit: homeassistant.UnitCycle}},
	})
	if err != nil {
		t.Fatal(err)
	}
	rule, err := automation.SaveLinkageRule(ctx, homeassistant.LinkageRule{
		FamilyID: familyID, CreatedByUserID: userID, IntegrationID: integrationID, Name: "Washer",
		EntityID: "sensor.washer", ApplianceDomain: "sensor", RecipeID: recipe.ID,
		StartState: "running", CompleteState: "completed", Enabled: true, RequiresConfirmation: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	events := NewEventRepository(db)
	doors := []homeassistant.NightDoor{{IntegrationID: integrationID, EntityID: "binary_sensor.door"}}
	targets, err := events.ListEventTargets(ctx, doors)
	if err != nil || len(targets) != 2 || targets[0].EntityID != doors[0].EntityID ||
		targets[0].TimeZone != "Asia/Shanghai" || targets[1].LinkageRuleID != rule.ID {
		t.Fatalf("wrong selected targets: %#v %v", targets, err)
	}
	start := time.Now().UTC().Add(time.Second)
	for i := 0; i < 2; i++ {
		claimed, err := NewEventRepository(db).ClaimDoorOpening(ctx, targets[0], start)
		if err != nil || claimed != (i == 0) {
			t.Fatalf("door event claim = %v %v", claimed, err)
		}
	}
	event := homeassistant.HAEvent{
		IntegrationID: integrationID, EntityID: "sensor.washer", Domain: "sensor",
		ApplianceRunID: "cycle-one", ObservedRuleID: rule.ID, ObservedStartAt: start,
		State: "completed", OccurredAt: start.Add(time.Minute),
	}
	if outcome, err := automation.ProcessEvent(ctx, familyID, event, event.OccurredAt); err == nil || outcome.Suggestion != nil {
		t.Fatalf("completion without a recorded start produced a suggestion: %#v %v", outcome, err)
	}
	event.State, event.OccurredAt = "running", start
	if outcome, err := automation.ProcessEvent(ctx, familyID, event, start); err != nil || outcome.Run == nil || outcome.Suggestion != nil {
		t.Fatalf("running result: %#v %v", outcome, err)
	}
	event.State, event.OccurredAt = "completed", start.Add(time.Minute)
	for i := 0; i < 2; i++ {
		outcome, err := NewAutomationRepository(db).ProcessEvent(ctx, familyID, event, event.OccurredAt)
		if err != nil || outcome.Suggestion == nil || outcome.Suggestion.Status != homeassistant.SuggestionPending || outcome.Duplicate != (i > 0) {
			t.Fatalf("completion result: %#v %v", outcome, err)
		}
	}
	var suggestions, quantity int
	if err := db.QueryRowContext(ctx, "SELECT count(*) FROM ha_linkage_suggestions").Scan(&suggestions); err != nil || suggestions != 1 {
		t.Fatalf("suggestions = %d, %v", suggestions, err)
	}
	if err := db.QueryRowContext(ctx, "SELECT quantity FROM product_batches").Scan(&quantity); err != nil || quantity != 3 {
		t.Fatalf("automatic inventory modification: quantity=%d %v", quantity, err)
	}
}
