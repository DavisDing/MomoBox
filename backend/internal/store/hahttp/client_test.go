package hahttp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/momobox/backend/internal/homeassistant"
)

const testToken = "0123456789abcdef"

func TestExecuteBrightnessUsesFixedEndpointAndTypedPayload(t *testing.T) {
	t.Parallel()
	var received map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/services/light/turn_on" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+testToken {
			t.Fatalf("unexpected authorization header")
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[{"entity_id":"light.kitchen","state":"on","attributes":{"brightness":128}}]`))
	}))
	defer server.Close()

	brightness := 50
	client := New(server.Client())
	result, err := client.Execute(context.Background(), server.URL, testToken, homeassistant.CommandInvocation{
		EntityID: "light.kitchen",
		Domain:   "light",
		Command:  homeassistant.CommandSetBrightness,
		Parameters: homeassistant.CommandParameters{
			Brightness: &brightness,
		},
	})
	if err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !result.Accepted || result.State == nil || result.State.EntityID != "light.kitchen" {
		t.Fatalf("unexpected command result: %+v", result)
	}
	if received["entity_id"] != "light.kitchen" || received["brightness_pct"] != float64(50) {
		t.Fatalf("unexpected typed payload: %#v", received)
	}
	for _, forbidden := range []string{"domain", "service", "service_data"} {
		if _, ok := received[forbidden]; ok {
			t.Fatalf("typed payload exposed forbidden key %q", forbidden)
		}
	}
}

func TestExecuteRejectsDomainMismatchWithoutNetworkCall(t *testing.T) {
	t.Parallel()
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		calls.Add(1)
	}))
	defer server.Close()

	client := New(server.Client())
	_, err := client.Execute(context.Background(), server.URL, testToken, homeassistant.CommandInvocation{
		EntityID: "light.kitchen",
		Domain:   "switch",
		Command:  homeassistant.CommandTurnOn,
	})
	if err == nil {
		t.Fatal("expected domain mismatch to be rejected")
	}
	if calls.Load() != 0 {
		t.Fatalf("invalid invocation made %d network calls", calls.Load())
	}
}

func TestExecuteSupportsOnlyFixedTypedCommandMappings(t *testing.T) {
	t.Parallel()
	brightness := 50
	temperature := 21.5
	tests := []struct {
		name        string
		invocation  homeassistant.CommandInvocation
		wantDomain  string
		wantService string
	}{
		{"turn_on", homeassistant.CommandInvocation{EntityID: "switch.kettle", Domain: "switch", Command: homeassistant.CommandTurnOn}, "switch", "turn_on"},
		{"turn_off", homeassistant.CommandInvocation{EntityID: "fan.office", Domain: "fan", Command: homeassistant.CommandTurnOff}, "fan", "turn_off"},
		{"toggle", homeassistant.CommandInvocation{EntityID: "light.hall", Domain: "light", Command: homeassistant.CommandToggle}, "light", "toggle"},
		{"brightness", homeassistant.CommandInvocation{EntityID: "light.hall", Domain: "light", Command: homeassistant.CommandSetBrightness, Parameters: homeassistant.CommandParameters{Brightness: &brightness}}, "light", "turn_on"},
		{"temperature", homeassistant.CommandInvocation{EntityID: "climate.room", Domain: "climate", Command: homeassistant.CommandSetTemperature, Parameters: homeassistant.CommandParameters{Temperature: &temperature}}, "climate", "set_temperature"},
		{"hvac", homeassistant.CommandInvocation{EntityID: "climate.room", Domain: "climate", Command: homeassistant.CommandSetHVACMode, Parameters: homeassistant.CommandParameters{HVACMode: "heat"}}, "climate", "set_hvac_mode"},
		{"play", homeassistant.CommandInvocation{EntityID: "media_player.tv", Domain: "media_player", Command: homeassistant.CommandPlay}, "media_player", "media_play"},
		{"pause", homeassistant.CommandInvocation{EntityID: "media_player.tv", Domain: "media_player", Command: homeassistant.CommandPause}, "media_player", "media_pause"},
		{"scene", homeassistant.CommandInvocation{EntityID: "scene.dinner", Domain: "scene", Command: homeassistant.CommandActivateScene}, "scene", "turn_on"},
		{"script", homeassistant.CommandInvocation{EntityID: "script.cleanup", Domain: "script", Command: homeassistant.CommandRunScript}, "script", "turn_on"},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			domain, service, _, err := typedServiceCall(test.invocation)
			if err != nil {
				t.Fatalf("typedServiceCall returned error: %v", err)
			}
			if domain != test.wantDomain || service != test.wantService {
				t.Fatalf("got %s/%s, want %s/%s", domain, service, test.wantDomain, test.wantService)
			}
		})
	}

	if _, _, _, err := typedServiceCall(homeassistant.CommandInvocation{
		EntityID: "light.hall",
		Domain:   "light",
		Command:  homeassistant.Command("raw_service"),
	}); err == nil {
		t.Fatal("expected arbitrary command to be rejected")
	}
}

func TestClientDoesNotFollowRedirectWithAuthorization(t *testing.T) {
	t.Parallel()
	var targetCalls atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		targetCalls.Add(1)
	}))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()

	client := New(redirect.Client())
	result, err := client.Test(context.Background(), redirect.URL, testToken)
	if err != nil {
		t.Fatalf("Test returned error: %v", err)
	}
	if result.Connected || result.ErrorCode != "unavailable" {
		t.Fatalf("unexpected redirect result: %+v", result)
	}
	if targetCalls.Load() != 0 {
		t.Fatalf("redirect target received %d calls", targetCalls.Load())
	}
}

func TestDiscoverBuildsSafeTypedEntities(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/states" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[
  {"entity_id":"light.kitchen","state":"on","attributes":{"friendly_name":"Kitchen","brightness":128,"device_id":"device-1","device_name":"Ceiling Light"}},
  {"entity_id":"climate.room","state":"heat","attributes":{"friendly_name":"Room","min_temp":16,"max_temp":30,"hvac_modes":["off","heat"]}},
  {"entity_id":"bad entity","state":"unknown","attributes":{}}
]`))
	}))
	defer server.Close()

	client := New(server.Client())
	client.now = func() time.Time { return time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC) }
	discovery, err := client.Discover(context.Background(), server.URL, testToken)
	if err != nil {
		t.Fatalf("Discover returned error: %v", err)
	}
	if len(discovery.Devices) != 1 || len(discovery.Entities) != 2 {
		t.Fatalf("unexpected discovery: %+v", discovery)
	}
	if !contains(discovery.Entities[0].Capabilities, "brightness") {
		t.Fatalf("light capabilities missing brightness: %#v", discovery.Entities[0].Capabilities)
	}
	if discovery.Entities[1].TemperatureMin == nil || *discovery.Entities[1].TemperatureMin != 16 {
		t.Fatalf("climate minimum temperature not decoded")
	}
}

func TestErrorsNeverContainAccessToken(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`not-json`))
	}))
	defer server.Close()

	client := New(server.Client())
	_, err := client.GetState(context.Background(), server.URL, testToken, homeassistant.HAEntity{EntityID: "light.kitchen"})
	if err == nil {
		t.Fatal("expected decoding error")
	}
	if strings.Contains(err.Error(), testToken) {
		t.Fatal("error leaked Home Assistant access token")
	}
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
