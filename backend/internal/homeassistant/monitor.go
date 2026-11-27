package homeassistant

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
)

type NightDoor struct {
	IntegrationID string `json:"integration_id"`
	EntityID      string `json:"entity_id"`
	NotifyAction  string `json:"notify_action"`
	Start         string `json:"start"`
	End           string `json:"end"`
}

var (
	doorEntity      = regexp.MustCompile(`^binary_sensor\.[a-z0-9_]{1,241}$`)
	companionAction = regexp.MustCompile(`^notify\.mobile_app_[a-z0-9_]{1,100}$`)
)

func ParseNightDoors(value string) ([]NightDoor, error) {
	if strings.TrimSpace(value) == "" {
		return nil, nil
	}
	var doors []NightDoor
	if err := json.Unmarshal([]byte(value), &doors); err != nil || doors == nil {
		return nil, fmt.Errorf("MOMO_HA_NIGHT_DOORS must be a JSON array")
	}
	seen := make(map[[2]string]bool)
	for index, door := range doors {
		door.IntegrationID = strings.ToLower(door.IntegrationID)
		key := [2]string{door.IntegrationID, door.EntityID}
		if !validateUUIDLike(door.IntegrationID) || !doorEntity.MatchString(door.EntityID) ||
			!companionAction.MatchString(door.NotifyAction) ||
			!validNightWindow(door.Start, door.End) || seen[key] {
			return nil, fmt.Errorf("invalid or duplicate MOMO_HA_NIGHT_DOORS entry %d", index+1)
		}
		seen[key] = true
		doors[index] = door
	}
	return doors, nil
}

func validNightWindow(start, end string) bool {
	a, aErr := time.Parse("15:04", start)
	b, bErr := time.Parse("15:04", end)
	return aErr == nil && bErr == nil &&
		a.Format("15:04") == start && b.Format("15:04") == end && start != end
}

func (d NightDoor) includes(occurredAt time.Time, zone *time.Location) bool {
	local := occurredAt.In(zone).Format("15:04")
	if d.Start < d.End {
		return local >= d.Start && local < d.End
	}
	return local >= d.Start || local < d.End
}

type StateTransition struct {
	EntityID    string
	From        string
	To          string
	ChangedFrom time.Time
	ChangedAt   time.Time
}

type EventTarget struct {
	FamilyID      string
	IntegrationID string
	EntityID      string
	Domain        string
	Name          string
	TimeZone      string
	LinkageRuleID string
}

type EventStore interface {
	ListEventTargets(context.Context, []NightDoor) ([]EventTarget, error)
	ClaimDoorOpening(context.Context, EventTarget, time.Time) (bool, error)
}

type EventClient interface {
	SubscribeStateChanges(ctx context.Context, baseURL, token string, entityIDs []string, receive func(StateTransition)) error
	NotifyCompanion(ctx context.Context, baseURL, token, action, title, message string) error
}

type EventMonitor struct {
	Service *Service
	Store   EventStore
	Client  EventClient
	Doors   []NightDoor
}

type eventConnection struct {
	baseURL, token string
	targets        []EventTarget
}

func (m *EventMonitor) Run(ctx context.Context) {
	type worker struct {
		connection eventConnection
		stop       context.CancelFunc
	}
	var workers sync.WaitGroup
	defer workers.Wait()
	active := make(map[string]worker)
	defer func() {
		for _, current := range active {
			current.stop()
		}
	}()
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for ctx.Err() == nil {
		connections, err := m.connections(ctx)
		if err != nil {
			if ctx.Err() == nil {
				log.Print("HA event monitor could not refresh its subscriptions")
			}
		} else {
			for id, current := range active {
				next := connections[id]
				if current.connection.baseURL != next.baseURL || current.connection.token != next.token ||
					!slices.Equal(current.connection.targets, next.targets) {
					current.stop()
					delete(active, id)
				}
			}
			for id, connection := range connections {
				if _, exists := active[id]; exists {
					continue
				}
				workerCtx, stop := context.WithCancel(ctx)
				active[id] = worker{connection: connection, stop: stop}
				workers.Add(1)
				go func(connection eventConnection) {
					defer workers.Done()
					m.subscribe(workerCtx, connection)
				}(connection)
			}
		}
		select {
		case <-ctx.Done():
		case <-ticker.C:
		}
	}
}

func (m *EventMonitor) connections(ctx context.Context) (map[string]eventConnection, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	targets, err := m.Store.ListEventTargets(ctx, m.Doors)
	if err != nil {
		return nil, err
	}
	connections := make(map[string]eventConnection)
	skipped := make(map[string]bool)
	for _, target := range targets {
		id := target.IntegrationID
		if skipped[id] {
			continue
		}
		connection, exists := connections[id]
		if !exists {
			integration, token, err := m.Service.integrationWithToken(ctx, target.FamilyID, id)
			if err != nil {
				skipped[id] = true
				log.Printf("HA event monitor could not load integration %s", id)
				continue
			}
			connection.baseURL = integration.BaseURL
			connection.token = token
		}
		connection.targets = append(connection.targets, target)
		connections[id] = connection
	}
	return connections, nil
}

func (m *EventMonitor) subscribe(ctx context.Context, connection eventConnection) {
	targets := make(map[string]EventTarget)
	entities := make([]string, 0, len(connection.targets))
	for _, target := range connection.targets {
		targets[target.EntityID] = target
		entities = append(entities, target.EntityID)
	}
	for ctx.Err() == nil {
		err := m.Client.SubscribeStateChanges(ctx, connection.baseURL, connection.token, entities, func(change StateTransition) {
			target, watched := targets[change.EntityID]
			if watched && validTransition(change, m.Service.now()) {
				m.handleChange(ctx, connection, target, change)
			}
		})
		if err != nil && ctx.Err() == nil {
			log.Printf("HA event subscription disconnected for integration %s, reconnecting", connection.targets[0].IntegrationID)
		}
		timer := time.NewTimer(5 * time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
		case <-timer.C:
		}
	}
}

func validTransition(change StateTransition, now time.Time) bool {
	for _, state := range []string{change.From, change.To} {
		switch strings.ToLower(strings.TrimSpace(state)) {
		case "", "unknown", "unavailable":
			return false
		}
	}
	return change.From != change.To && !change.ChangedFrom.IsZero() &&
		change.ChangedAt.After(change.ChangedFrom) &&
		!change.ChangedAt.Before(now.Add(-5*time.Minute)) && !change.ChangedAt.After(now.Add(time.Minute))
}

func (m *EventMonitor) handleChange(ctx context.Context, connection eventConnection, target EventTarget, change StateTransition) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	// In-flight events from an old connection cannot act on a replacement HA.
	current, token, err := m.Service.integrationWithToken(ctx, target.FamilyID, target.IntegrationID)
	if err != nil || current.BaseURL != connection.baseURL || token != connection.token {
		return
	}
	if event, ok := applianceEvent(target, change); ok {
		trusted := TrustedEventContext(ctx, target.FamilyID, target.IntegrationID)
		if _, err := m.Service.processTrustedHAEvent(trusted, target.FamilyID, event); err != nil {
			if !isNotFound(err) && ctx.Err() == nil {
				log.Printf("HA appliance event could not be processed for integration %s", target.IntegrationID)
			}
		}
	}
	if change.From != "off" || change.To != "on" {
		return
	}
	for _, door := range m.Doors {
		if door.IntegrationID == target.IntegrationID && door.EntityID == target.EntityID {
			m.notifyDoor(ctx, connection, target, door, change.ChangedAt)
			break
		}
	}
}

func applianceEvent(target EventTarget, change StateTransition) (HAEvent, bool) {
	if target.LinkageRuleID == "" {
		return HAEvent{}, false
	}
	before, _ := NormalizeHAState(change.From)
	after, _ := NormalizeHAState(change.To)
	startedAt := change.ChangedAt
	switch {
	case after == "running" && before != "running":
	case after == "completed" && before == "running":
		startedAt = change.ChangedFrom
	default:
		return HAEvent{}, false
	}
	return HAEvent{
		IntegrationID: target.IntegrationID, EntityID: target.EntityID, Domain: target.Domain,
		ApplianceRunID: "ha:" + startedAt.UTC().Format(time.RFC3339Nano),
		State:          after, PreviousState: before, OccurredAt: change.ChangedAt,
		ObservedRuleID: target.LinkageRuleID, ObservedStartAt: startedAt,
	}, true
}

func (m *EventMonitor) notifyDoor(ctx context.Context, connection eventConnection, target EventTarget, door NightDoor, occurredAt time.Time) {
	zone, err := time.LoadLocation(target.TimeZone)
	if err != nil || target.TimeZone == "" || target.TimeZone == "Local" {
		log.Printf("HA door notification skipped for integration %s due to invalid family time zone", target.IntegrationID)
		return
	}
	if !door.includes(occurredAt, zone) {
		return
	}
	claimed, err := m.Store.ClaimDoorOpening(ctx, target, occurredAt)
	if err != nil {
		log.Printf("HA door notification could not record delivery for integration %s", target.IntegrationID)
		return
	}
	if !claimed {
		return
	}
	// The unique claim is committed before calling HA. An ambiguous result
	// cannot safely be retried without risking a second phone notification.
	message := fmt.Sprintf("%s于 %s 打开。", target.Name, occurredAt.In(zone).Format("15:04"))
	if err := m.Client.NotifyCompanion(ctx, connection.baseURL, connection.token, door.NotifyAction, "夜间开门提醒", message); err != nil {
		log.Printf("HA Companion notification was not confirmed for integration %s", target.IntegrationID)
	}
}
