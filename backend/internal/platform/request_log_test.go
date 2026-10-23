package platform

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRequestLogsContainTemplateAndExcludeRequestSecrets(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logs, nil))
	mux := http.NewServeMux()
	mux.HandleFunc("/items/{id}", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusConflict) })
	handler := RequestIDMiddleware(RequestLogMiddleware(logger, RouteTemplateHandler(mux)))
	req := httptest.NewRequest(http.MethodGet, "/items/private-item-id?token=private-query", nil)
	req.Header.Set("Authorization", "Bearer private-bearer")
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	output := logs.String()
	for _, required := range []string{"/items/{id}", "request_id", "409", "duration_ms", "client_error", resp.Header().Get("X-Request-ID")} {
		if !strings.Contains(output, required) {
			t.Fatalf("missing %q: %s", required, output)
		}
	}
	for _, secret := range []string{"private-item-id", "private-query", "private-bearer"} {
		if strings.Contains(output, secret) {
			t.Fatalf("logged request secret %q", secret)
		}
	}
}
func TestRequestLogPreservesPanicWithoutLoggingPanicValue(t *testing.T) {
	var logs bytes.Buffer
	handler := RequestLogMiddleware(slog.New(slog.NewJSONHandler(&logs, nil)), http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic("secret body") }))
	defer func() {
		if recover() == nil {
			t.Fatal("panic was silently swallowed")
		}
		if strings.Contains(logs.String(), "secret body") || !strings.Contains(logs.String(), "panic") {
			t.Fatalf("unsafe panic log: %s", logs.String())
		}
	}()
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/private", nil))
}
