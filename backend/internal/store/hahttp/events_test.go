package hahttp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/momobox/backend/internal/homeassistant"
)

func TestHAStateSubscriptionAuthenticatesAndForwardsOnlySelectedTransitions(t *testing.T) {
	expected := []string{"binary_sensor.door", "sensor.washer"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/api/websocket" {
			t.Errorf("wrong subscription endpoint: %s", req.URL.Path)
		}
		conn, err := websocket.Accept(w, req, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.CloseNow()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := wsjson.Write(ctx, conn, map[string]string{"type": "auth_required"}); err != nil {
			t.Error(err)
			return
		}
		var auth map[string]string
		if err := wsjson.Read(ctx, conn, &auth); err != nil || auth["type"] != "auth" || auth["access_token"] != testToken {
			t.Error("invalid websocket authentication", err)
			return
		}
		if err := wsjson.Write(ctx, conn, map[string]string{"type": "auth_ok"}); err != nil {
			t.Error(err)
			return
		}
		var subscribe struct {
			Type    string `json:"type"`
			ID      int    `json:"id"`
			Trigger struct {
				Platform string   `json:"platform"`
				Entities []string `json:"entity_id"`
			} `json:"trigger"`
		}
		if err := wsjson.Read(ctx, conn, &subscribe); err != nil || subscribe.Type != "subscribe_trigger" ||
			subscribe.Trigger.Platform != "state" || !reflect.DeepEqual(subscribe.Trigger.Entities, expected) {
			t.Errorf("wrong subscription: %#v %v", subscribe, err)
			return
		}
		if err := wsjson.Write(ctx, conn, map[string]any{"id": subscribe.ID, "type": "result", "success": true}); err != nil {
			t.Error(err)
			return
		}
		now := time.Now().UTC()
		for _, entity := range []string{"binary_sensor.unselected", "binary_sensor.door", "sensor.washer"} {
			from := &triggerState{EntityID: entity, State: "off", LastChanged: now.Add(-time.Hour)}
			if entity == "binary_sensor.door" {
				from = nil // Initial state has no previous state and must be ignored.
			}
			message := map[string]any{"id": subscribe.ID, "type": "event", "event": map[string]any{
				"variables": map[string]any{"trigger": map[string]any{
					"entity_id": entity, "from_state": from,
					"to_state": triggerState{EntityID: entity, State: "on", LastChanged: now},
				}},
			}}
			if err := wsjson.Write(ctx, conn, message); err != nil {
				t.Error(err)
				return
			}
		}
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var received []homeassistant.StateTransition
	_ = New(server.Client()).SubscribeStateChanges(ctx, server.URL, testToken, expected,
		func(change homeassistant.StateTransition) { received = append(received, change) })
	if len(received) != 1 || received[0].EntityID != "sensor.washer" || received[0].From != "off" ||
		received[0].To != "on" || !received[0].ChangedAt.After(received[0].ChangedFrom) {
		t.Fatalf("wrong forwarded events: %#v", received)
	}
}

func TestHARoutineRESTReportsAcceptanceAndExplicitRejection(t *testing.T) {
	for _, test := range []struct {
		command homeassistant.Command
		entity  string
		domain  string
		status  int
	}{
		{homeassistant.CommandActivateScene, "scene.goodnight", "scene", http.StatusOK},
		{homeassistant.CommandRunScript, "script.goodnight", "script", http.StatusNotFound},
	} {
		t.Run(test.domain, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				var body map[string]any
				if err := json.NewDecoder(req.Body).Decode(&body); err != nil || len(body) != 1 || body["entity_id"] != test.entity {
					t.Errorf("unexpected request body: %v, %v", body, err)
				}
				if req.Method != http.MethodPost || req.URL.Path != "/api/services/"+test.domain+"/turn_on" {
					t.Errorf("unexpected endpoint %s %s", req.Method, req.URL.Path)
				}
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(`[{"entity_id":"light.bedroom","state":"off"}]`))
			}))
			defer server.Close()
			result, err := New(server.Client()).Execute(context.Background(), server.URL, testToken,
				homeassistant.CommandInvocation{Domain: test.domain, EntityID: test.entity, Command: test.command})
			if err != nil || result.Accepted != (test.status == http.StatusOK) || result.State != nil {
				t.Fatalf("unexpected receipt: %#v, %v", result, err)
			}
		})
	}
}
