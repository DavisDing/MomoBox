package processing

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestGatewayModelsAndSelectedAlias(t *testing.T) {
	calls := 0
	config := AIConfig{Endpoints: []AIEndpoint{{Endpoint: "http://litellm:4000/v1", Key: "server-key", Model: "default", Protocol: "chat", Level: "primary"}},
		Client: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.Method != "GET" || r.URL.String() != "http://litellm:4000/v1/models" || r.Header.Get("Authorization") != "Bearer server-key" {
				t.Fatalf("unexpected model-list request: %s %s", r.Method, r.URL)
			}
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"data":[{"id":"family-fast","api_key":"do-not-return"},{"id":"family-fast"},{"id":"family-smart"},{"id":"bad\nmodel"}]}`))}, nil
		})}}
	models, err := config.Models(context.Background())
	if err != nil || len(models) != 3 || models[0].ID != "family-fast" || !models[2].Default {
		t.Fatalf("models=%v error=%v", models, err)
	}
	selected, err := config.selectModel(context.Background(), "family-smart")
	if err != nil || len(selected.Endpoints) != 1 || selected.Endpoints[0].Model != "family-smart" || selected.Endpoints[0].Key != "server-key" {
		t.Fatalf("selection failed: %v", err)
	}
	if _, err = config.selectModel(context.Background(), "not-allowed"); err != ErrInvalid {
		t.Fatalf("unlisted model accepted: %v", err)
	}
	if calls != 3 {
		t.Fatalf("unexpected calls %d", calls)
	}
}

func TestExplicitModelAllowlistAndNoCatalogFallbackLeaks(t *testing.T) {
	config := AIConfig{Endpoints: []AIEndpoint{{Endpoint: "http://gateway/v1", Model: "hidden", Protocol: "chat"}}, AllowedModels: []string{"safe", "safe"}}
	models, err := config.Models(context.Background())
	if err != nil || len(models) != 1 || models[0].ID != "safe" || !models[0].Default {
		t.Fatalf("models=%v error=%v", models, err)
	}
	if _, err = config.selectModel(context.Background(), "hidden"); err != ErrInvalid {
		t.Fatal("allowlist bypass")
	}
	selected, err := config.selectModel(context.Background(), "")
	if err != nil || selected.Endpoints[0].Model != "safe" {
		t.Fatal("default selection failed")
	}
	config.AllowedModels = nil
	config.Client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 404, Body: io.NopCloser(strings.NewReader("unsupported"))}, nil
	})}
	models, err = config.Models(context.Background())
	if err != nil || len(models) != 1 || models[0].ID != "hidden" {
		t.Fatal("explicit default unavailable when /models unsupported")
	}
}
