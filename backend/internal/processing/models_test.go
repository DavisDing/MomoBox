package processing

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
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

func TestModelCatalogURLFormsAndRouteFallback(t *testing.T) {
	for _, scenario := range []struct {
		endpoint string
		paths    []string
	}{
		{"http://gateway", []string{"/v1/models", "/models"}},
		{"http://gateway/v1/", []string{"/v1/models", "/models"}},
		{"http://gateway/proxy", []string{"/proxy/models", "/proxy/v1/models"}},
		{"http://gateway/proxy/v1", []string{"/proxy/v1/models", "/proxy/models"}},
		{"http://gateway/models", []string{"/models", "/v1/models"}},
		{"http://gateway/proxy/v1/models", []string{"/proxy/v1/models", "/proxy/models"}},
		{"http://gateway/proxy/v1/chat/completions", []string{"/proxy/v1/models", "/proxy/models"}},
		{"http://gateway/proxy/v1/responses", []string{"/proxy/v1/models", "/proxy/models"}},
	} {
		t.Run(scenario.endpoint, func(t *testing.T) {
			for _, fallback := range []bool{false, true} {
				calls := 0
				config := AIConfig{Endpoints: []AIEndpoint{{Endpoint: scenario.endpoint, Key: " key \n"}}, Client: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
					if calls >= len(scenario.paths) || r.Method != "GET" || r.URL.Path != scenario.paths[calls] || r.Header.Get("Authorization") != "Bearer key" {
						t.Fatalf("unexpected request %d: %s %s", calls, r.Method, r.URL.Path)
					}
					calls++
					if fallback && calls == 1 {
						return &http.Response{StatusCode: 405, Body: io.NopCloser(strings.NewReader("unsupported"))}, nil
					}
					return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"data":[{"id":"model"}]}`))}, nil
				})}}
				models, err := config.Models(context.Background())
				wantCalls := 1
				if fallback {
					wantCalls = 2
				}
				if err != nil || len(models) != 1 || !models[0].Default || calls != wantCalls {
					t.Fatalf("models=%v err=%v calls=%d", models, err, calls)
				}
			}
		})
	}
}

func TestModelCatalogClassifiesFailuresWithoutLeakingOrProbingInference(t *testing.T) {
	for _, scenario := range []struct {
		name         string
		status       int
		body         string
		transportErr error
		code         string
		calls        int
	}{
		{"key rejected", 401, "server-secret http://private-gateway", nil, "AI_MODELS_AUTH_FAILED", 1},
		{"models forbidden", 403, "private data", nil, "AI_MODELS_AUTH_FAILED", 1},
		{"route missing", 404, "missing", nil, "AI_MODELS_NOT_FOUND", 2},
		{"server failure", 503, "private data", nil, "AI_MODELS_UPSTREAM_FAILED", 1},
		{"redirect", 302, "redirect", nil, "AI_MODELS_REDIRECT", 1},
		{"html page", 200, "<html>login</html>", nil, "AI_MODELS_INVALID_RESPONSE", 1},
		{"no data field", 200, `{"models":[]}`, nil, "AI_MODELS_INVALID_RESPONSE", 1},
		{"null data", 200, `{"data":null}`, nil, "AI_MODELS_INVALID_RESPONSE", 1},
		{"invalid data", 200, `{"data":{}}`, nil, "AI_MODELS_INVALID_RESPONSE", 1},
		{"too large", 200, strings.Repeat("x", (1<<20)+1), nil, "AI_MODELS_INVALID_RESPONSE", 1},
		{"empty catalog", 200, `{"data":[]}`, nil, "AI_MODELS_EMPTY", 1},
		{"no usable IDs", 200, `{"data":[{"id":"bad\nname"}]}`, nil, "AI_MODELS_EMPTY", 1},
		{"container stopped", 0, "", errors.New("http://private-gateway server-secret connection refused"), "AI_MODELS_UNREACHABLE", 1},
		{"timeout", 0, "", context.DeadlineExceeded, "AI_MODELS_TIMEOUT", 1},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			calls := 0
			config := AIConfig{Endpoints: []AIEndpoint{{Endpoint: "http://private-gateway/v1", Key: "server-secret"}}, Client: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Method != "GET" || !strings.HasSuffix(r.URL.Path, "/models") {
					t.Fatal("inference probed")
				}
				if scenario.transportErr != nil {
					return nil, scenario.transportErr
				}
				return &http.Response{StatusCode: scenario.status, Body: io.NopCloser(strings.NewReader(scenario.body))}, nil
			})}}
			_, err := config.Models(context.Background())
			var catalog *ModelCatalogError
			if !errors.As(err, &catalog) || catalog.Code != scenario.code || calls != scenario.calls || !errors.Is(err, ErrUnavailable) {
				t.Fatalf("error=%v calls=%d", err, calls)
			}
			if strings.Contains(err.Error(), "secret") || strings.Contains(err.Error(), "gateway") {
				t.Fatal("error leaked upstream data")
			}
		})
	}
}

func TestModelCatalogRejectsCredentialedRedirectEvenWithCustomClient(t *testing.T) {
	var destinationCalls int
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		destinationCalls++
		w.Write([]byte(`{"data":[{"id":"leaked"}]}`))
	}))
	defer destination.Close()
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL+"/models", http.StatusFound)
	}))
	defer gateway.Close()
	config := AIConfig{Endpoints: []AIEndpoint{{Endpoint: gateway.URL, Key: "server-secret"}}, Client: &http.Client{}}
	_, err := config.Models(context.Background())
	var catalog *ModelCatalogError
	if !errors.As(err, &catalog) || catalog.Code != "AI_MODELS_REDIRECT" || destinationCalls != 0 {
		t.Fatalf("error=%v destination calls=%d", err, destinationCalls)
	}
}

func TestURLKeyOnlyConfigAndModelsURLInference(t *testing.T) {
	t.Setenv("AI_ENDPOINT", "http://gateway/v1/models/")
	t.Setenv("AI_API_KEY", "  server-key\n")
	t.Setenv("AI_MODEL", "")
	t.Setenv("AI_MODELS", "")
	t.Setenv("AI_PROTOCOL", "auto")
	t.Setenv("AI_SECONDARY_ENDPOINT", "")
	t.Setenv("AI_FALLBACK_ENDPOINT", "")
	config := AIFromEnv()
	if len(config.Endpoints) != 1 || config.Endpoints[0].Key != "server-key" || config.Endpoints[0].Model != "" {
		t.Fatalf("invalid parsed config")
	}
	config.Endpoints[0].Model = "selected"
	config.Client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != "POST" || r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("unexpected inference destination: %s", r.URL.Path)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"choices":[{"message":{"content":"OK"}}]}`))}, nil
	})}
	if _, err := config.call(context.Background(), AIRequest{User: "hello"}); err != nil {
		t.Fatal(err)
	}
}
