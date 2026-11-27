package homeassistant

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWasherEventUsesObservedStartForReplayedCompletion(t *testing.T) {
	start := time.Date(2026, 11, 27, 12, 2, 0, 0, time.UTC)
	end := start.Add(90 * time.Minute)
	target := EventTarget{IntegrationID: "ha", EntityID: "sensor.washer", Domain: "sensor", LinkageRuleID: "rule"}
	running := StateTransition{From: "idle", To: "running", ChangedFrom: start.Add(-time.Hour), ChangedAt: start}
	finished := StateTransition{From: "running", To: "finished", ChangedFrom: start, ChangedAt: end}
	first, ok := applianceEvent(target, running)
	if !ok || first.State != "running" {
		t.Fatalf("invalid start event: %#v", first)
	}
	for i := 0; i < 2; i++ {
		next, ok := applianceEvent(target, finished)
		if !ok || next.State != "completed" || next.ApplianceRunID != first.ApplianceRunID ||
			next.ObservedRuleID != target.LinkageRuleID || !next.ObservedStartAt.Equal(start) {
			t.Fatalf("completion changed run identity: %#v", next)
		}
	}
	if _, ok := applianceEvent(target, StateTransition{From: "idle", To: "finished"}); ok {
		t.Fatal("completion with no running state accepted")
	}
}

func TestHAEventIgnoresSnapshotsAttributeUpdatesAndStaleChanges(t *testing.T) {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)
	for name, event := range map[string]StateTransition{
		"initial snapshot":   {To: "on", ChangedAt: now},
		"reconnect snapshot": {From: "on", To: "on", ChangedFrom: now.Add(-time.Minute), ChangedAt: now},
		"restored entity":    {From: "unavailable", To: "on", ChangedFrom: now.Add(-time.Minute), ChangedAt: now},
		"attribute update":   {From: "off", To: "off", ChangedFrom: now, ChangedAt: now},
		"stale replay":       {From: "off", To: "on", ChangedFrom: now.Add(-time.Hour), ChangedAt: now.Add(-time.Minute * 10)},
		"backward timestamp": {From: "off", To: "on", ChangedFrom: now, ChangedAt: now.Add(-time.Second)},
	} {
		t.Run(name, func(t *testing.T) {
			if validTransition(event, now) {
				t.Fatalf("unexpected transition: %#v", event)
			}
		})
	}
	if !validTransition(StateTransition{From: "off", To: "on", ChangedFrom: now.Add(-time.Minute), ChangedAt: now}, now) {
		t.Fatal("live off -> on transition ignored")
	}
}

type memoryDoorStore struct {
	EventStore
	claims map[time.Time]bool
}

func (s *memoryDoorStore) ClaimDoorOpening(_ context.Context, _ EventTarget, occurredAt time.Time) (bool, error) {
	if s.claims[occurredAt] {
		return false, nil
	}
	s.claims[occurredAt] = true
	return true, nil
}

type doorEventClient struct {
	EventClient
	actions []string
}

func (c *doorEventClient) NotifyCompanion(_ context.Context, _, _, action, _, _ string) error {
	c.actions = append(c.actions, action)
	return errors.New("delivery unknown")
}

func TestNightDoorUsesFamilyTimeAndClaimsOnlyOnce(t *testing.T) {
	doors, err := ParseNightDoors(`[{"integration_id":"11111111-1111-4111-8111-111111111111","entity_id":"binary_sensor.door","notify_action":"notify.mobile_app_phone","start":"22:00","end":"07:00"}]`)
	if err != nil || len(doors) != 1 {
		t.Fatalf("valid config rejected: %v", err)
	}
	for _, invalid := range []string{"notify.persistent_notification", "notify.mobile_app_../bad"} {
		copy := doors[0]
		copy.NotifyAction = invalid
		if companionAction.MatchString(copy.NotifyAction) {
			t.Fatalf("unsafe action allowed: %s", invalid)
		}
	}
	door := doors[0]
	store := &memoryDoorStore{claims: make(map[time.Time]bool)}
	client := &doorEventClient{}
	monitor := EventMonitor{Store: store, Client: client}
	target := EventTarget{IntegrationID: door.IntegrationID, EntityID: door.EntityID, Name: "前门", TimeZone: "Asia/Shanghai"}
	start := time.Date(2026, 11, 27, 14, 0, 0, 0, time.UTC) // 22:00 local.
	for _, at := range []time.Time{start.Add(-time.Second), start, start, start.Add(3 * time.Hour), start.Add(9 * time.Hour)} {
		monitor.notifyDoor(context.Background(), eventConnection{}, target, door, at)
	}
	if len(store.claims) != 2 || len(client.actions) != 2 || client.actions[0] != door.NotifyAction {
		t.Fatalf("expected one attempt per nighttime opening: %v %v", store.claims, client.actions)
	}
}
