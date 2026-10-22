package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
	syncdomain "github.com/momobox/backend/internal/sync"
)

type importHTTPFixture struct {
	SyncService
	calls   int
	actor   syncdomain.DeviceScope
	request syncdomain.ImportRequest
}

func (s *importHTTPFixture) ImportCapabilities(_ context.Context, actor syncdomain.DeviceScope) (syncdomain.ImportCapabilities, error) {
	s.calls++
	s.actor = actor
	return syncdomain.ImportCapabilities{ImportFormatVersion: 1, FamilyTimeZone: "Asia/Shanghai"}, nil
}

func (s *importHTTPFixture) PreflightImport(_ context.Context, actor syncdomain.DeviceScope, request syncdomain.ImportRequest) (syncdomain.ImportReceipt, error) {
	s.calls++
	s.actor = actor
	s.request = request
	return syncdomain.ImportReceipt{ImportID: request.ImportID, Status: "prepared", Ready: true}, nil
}

func (s *importHTTPFixture) ConfirmImport(context.Context, syncdomain.DeviceScope, string, syncdomain.ImportConfirmRequest) (syncdomain.ImportReceipt, error) {
	s.calls++
	return syncdomain.ImportReceipt{}, nil
}

func (s *importHTTPFixture) ImportReceipt(context.Context, syncdomain.DeviceScope, string) (syncdomain.ImportReceipt, error) {
	s.calls++
	return syncdomain.ImportReceipt{}, nil
}

func (s *importHTTPFixture) ImportHistory(context.Context, syncdomain.DeviceScope, syncdomain.ImportHistoryRequest) (syncdomain.ImportHistoryPage, error) {
	s.calls++
	return syncdomain.ImportHistoryPage{}, nil
}

func importHTTPRouter(service *importHTTPFixture) http.Handler {
	return NewRouter(Dependencies{
		Sync: service,
		Verifier: testVerifier{claims: auth.AccessTokenClaims{
			UserID: "user", FamilyID: "family", DeviceID: "device", ExpiresAt: time.Now().Add(time.Hour),
		}},
	})
}

func importHTTPRequest(method, path, body string) *http.Request {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer token")
	r.Header.Set("Content-Type", "application/json")
	return r
}

func TestImportHTTPUsesAuthenticatedIdentityAndChecksDevice(t *testing.T) {
	service := &importHTTPFixture{}
	handler := importHTTPRouter(service)
	r := importHTTPRequest(http.MethodPost, "/api/v1/sync/import/preflight", `{"format_version":1,"import_id":"plan","local_workspace_id":"workspace","unsettled_outbox_count":0,"categories":[],"products":[],"product_batches":[],"shopping_items":[],"reminder_settings":[],"history":[]}`)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 200 || service.calls != 1 || service.actor.UserID != "user" || service.actor.FamilyID != "family" || service.request.DeviceID != "device" {
		t.Fatalf("identity dispatch failed: status=%d calls=%d", w.Code, service.calls)
	}
	for _, test := range []struct{ path, body string }{
		{"/api/v1/sync/import/preflight", `{"device_id":"other"}`},
		{"/api/v1/sync/import/plan/confirm", `{"device_id":"other"}`},
		{"/api/v1/sync/import/capabilities?device_id=other", ""},
	} {
		method := http.MethodPost
		if strings.Contains(test.path, "capabilities") {
			method = http.MethodGet
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, importHTTPRequest(method, test.path, test.body))
		if w.Code != 403 || service.calls != 1 {
			t.Fatalf("device mismatch dispatched: status=%d calls=%d", w.Code, service.calls)
		}
	}
}

func TestImportHTTPLimitsAndMalformedBodiesNeverDispatch(t *testing.T) {
	for _, body := range []string{
		`{"family_id":"forged"}`,
		`{"format_version":1} {}`,
		`{"local_workspace_id":"` + strings.Repeat("x", syncdomain.MaxImportBytes) + `"}`,
	} {
		service := &importHTTPFixture{}
		w := httptest.NewRecorder()
		importHTTPRouter(service).ServeHTTP(w, importHTTPRequest(http.MethodPost, "/api/v1/sync/import/preflight", body))
		if w.Code != 400 || service.calls != 0 {
			t.Fatalf("malformed/oversize dispatch: status=%d calls=%d", w.Code, service.calls)
		}
	}
	for _, query := range []string{"limit=0", "limit=501", "after=-1", "until=not-a-number"} {
		service := &importHTTPFixture{}
		w := httptest.NewRecorder()
		importHTTPRouter(service).ServeHTTP(w, importHTTPRequest(http.MethodGet, "/api/v1/sync/import/history?"+query, ""))
		if w.Code != 400 || service.calls != 0 {
			t.Fatalf("invalid paging dispatched: status=%d calls=%d", w.Code, service.calls)
		}
	}
}

func TestImportHTTPErrorMappingAndUnavailableCapability(t *testing.T) {
	for _, test := range []struct {
		code   string
		status int
	}{
		{"IMPORT_LIMIT_EXCEEDED", 400},
		{"IMPORT_UNSUPPORTED_FORMAT", 400},
		{"IMPORT_ID_REUSED", 409},
		{"IMPORT_CHECKPOINT_STALE", 409},
		{"IMPORT_BLOCKED", 409},
		{"IMPORT_NOT_AVAILABLE", 503},
	} {
		if got := syncStatus(test.code); got != test.status {
			t.Errorf("%s: status=%d", test.code, got)
		}
	}
	handler := NewRouter(Dependencies{Verifier: testVerifier{claims: auth.AccessTokenClaims{
		UserID: "u", FamilyID: "f", DeviceID: "d", ExpiresAt: time.Now().Add(time.Hour),
	}}})
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, importHTTPRequest(http.MethodGet, "/api/v1/sync/import/capabilities", ""))
	if w.Code != 503 {
		t.Fatalf("missing optional capability status=%d", w.Code)
	}
	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
}
