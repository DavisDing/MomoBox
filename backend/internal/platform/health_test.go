package platform

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type healthProbeDB struct {
	ping func(context.Context) error
}

var _ DB = healthProbeDB{}

func (db healthProbeDB) PingContext(ctx context.Context) error { return db.ping(ctx) }
func (db healthProbeDB) Close() error                          { return nil }

func healthResponse(db DB, request *http.Request) *httptest.ResponseRecorder {
	server := NewHTTPServer(Config{}, db)
	response := httptest.NewRecorder()
	server.HTTPServer.Handler.ServeHTTP(response, request)
	return response
}

func assertHealthResponse(t *testing.T, response *httptest.ResponseRecorder, code int, status, database string) {
	t.Helper()
	if response.Code != code {
		t.Fatalf("status = %d, want %d", response.Code, code)
	}
	if got := response.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", got)
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body) != 2 || body["status"] != status || body["database"] != database {
		t.Fatalf("unexpected health response: %#v", body)
	}
}

func TestHealthConnectivityContract(t *testing.T) {
	secretError := "postgres://private-user:private-password@private-host/private-db"
	for _, tt := range []struct {
		name     string
		db       DB
		code     int
		status   string
		database string
	}{
		{"nil database", nil, http.StatusServiceUnavailable, "degraded", "unavailable"},
		{"connected", healthProbeDB{ping: func(context.Context) error { return nil }}, http.StatusOK, "ok", "ok"},
		{"failed ping", healthProbeDB{ping: func(context.Context) error { return errors.New(secretError) }}, http.StatusServiceUnavailable, "degraded", "unavailable"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
			response := healthResponse(tt.db, request)
			assertHealthResponse(t, response, tt.code, tt.status, tt.database)
			if strings.Contains(response.Body.String(), secretError) {
				t.Fatal("health response exposes the raw database error")
			}
		})
	}
}

func TestHealthProbeDeadlineAndCleanup(t *testing.T) {
	if healthDatabaseTimeout <= 0 || healthDatabaseTimeout > 2*time.Second {
		t.Fatalf("database timeout = %v, want positive and at most 2s", healthDatabaseTimeout)
	}
	type valueKey struct{}
	parent := context.WithValue(context.Background(), valueKey{}, "request value")
	request := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil).WithContext(parent)
	before := time.Now()
	var probeContext context.Context
	calls := 0
	db := healthProbeDB{ping: func(ctx context.Context) error {
		calls++
		probeContext = ctx
		deadline, ok := ctx.Deadline()
		if !ok || deadline.Before(before.Add(healthDatabaseTimeout)) || deadline.After(time.Now().Add(healthDatabaseTimeout)) {
			t.Fatalf("probe deadline = %v, exists = %v; want bounded database deadline", deadline, ok)
		}
		if ctx.Value(valueKey{}) != "request value" {
			t.Fatal("probe lost request context values")
		}
		return nil
	}}
	assertHealthResponse(t, healthResponse(db, request), http.StatusOK, "ok", "ok")
	if calls != 1 {
		t.Fatalf("ping calls = %d, want 1", calls)
	}
	if !errors.Is(probeContext.Err(), context.Canceled) {
		t.Fatalf("probe context not released on success: %v", probeContext.Err())
	}
	if parent.Err() != nil {
		t.Fatalf("probe cleanup canceled request context: %v", parent.Err())
	}
}

func TestHealthDatabaseTimeout(t *testing.T) {
	// A later request deadline bounds the test if the independent probe timeout
	// regresses. Inspect the deadline before waiting, not a fragile wall-clock SLA.
	parent, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil).WithContext(parent)
	var probeError error
	db := healthProbeDB{ping: func(ctx context.Context) error {
		deadline, ok := ctx.Deadline()
		parentDeadline, _ := parent.Deadline()
		if !ok || !deadline.Before(parentDeadline) || time.Until(deadline) > 2*time.Second {
			t.Fatalf("probe has no independent short deadline: %v, exists = %v", deadline, ok)
		}
		<-ctx.Done()
		probeError = ctx.Err()
		return probeError
	}}
	response := healthResponse(db, request)
	assertHealthResponse(t, response, http.StatusServiceUnavailable, "degraded", "unavailable")
	if !errors.Is(probeError, context.DeadlineExceeded) {
		t.Fatalf("probe error = %v, want DeadlineExceeded", probeError)
	}
	if parent.Err() != nil {
		t.Fatalf("probe waited for or canceled request deadline: %v", parent.Err())
	}
}

func TestHealthRespectsEarlierRequestDeadline(t *testing.T) {
	parent, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	request := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil).WithContext(parent)
	var probeError error
	db := healthProbeDB{ping: func(ctx context.Context) error {
		deadline, ok := ctx.Deadline()
		parentDeadline, _ := parent.Deadline()
		if !ok || !deadline.Equal(parentDeadline) {
			t.Fatalf("probe extended request deadline: got %v, want %v", deadline, parentDeadline)
		}
		<-ctx.Done()
		probeError = ctx.Err()
		return probeError
	}}
	assertHealthResponse(t, healthResponse(db, request), http.StatusServiceUnavailable, "degraded", "unavailable")
	if !errors.Is(probeError, context.DeadlineExceeded) {
		t.Fatalf("probe error = %v, want DeadlineExceeded", probeError)
	}
}

func TestHealthRequestCancellation(t *testing.T) {
	for _, alreadyCanceled := range []bool{true, false} {
		name := "during probe"
		if alreadyCanceled {
			name = "before probe"
		}
		t.Run(name, func(t *testing.T) {
			parent, cancel := context.WithCancel(context.Background())
			defer cancel()
			if alreadyCanceled {
				cancel()
			}
			request := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil).WithContext(parent)
			calls := 0
			db := healthProbeDB{ping: func(ctx context.Context) error {
				calls++
				if alreadyCanceled && !errors.Is(ctx.Err(), context.Canceled) {
					t.Fatalf("probe did not inherit cancellation: %v", ctx.Err())
				}
				if !alreadyCanceled {
					cancel()
				}
				select {
				case <-ctx.Done():
				default:
					t.Fatal("request cancellation did not reach probe")
				}
				if !errors.Is(ctx.Err(), context.Canceled) {
					t.Fatalf("probe error = %v, want Canceled", ctx.Err())
				}
				return ctx.Err()
			}}
			assertHealthResponse(t, healthResponse(db, request), http.StatusServiceUnavailable, "degraded", "unavailable")
			if calls != 1 {
				t.Fatalf("ping calls = %d, want 1", calls)
			}
		})
	}
}

func TestHealthRejectsOtherMethodsWithoutProbing(t *testing.T) {
	for _, method := range []string{http.MethodHead, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodOptions} {
		t.Run(method, func(t *testing.T) {
			calls := 0
			db := healthProbeDB{ping: func(context.Context) error {
				calls++
				return errors.New("private database error")
			}}
			request := httptest.NewRequest(method, "/api/v1/health", nil)
			response := healthResponse(db, request)
			if response.Code != http.StatusMethodNotAllowed {
				t.Fatalf("status = %d, want 405", response.Code)
			}
			if calls != 0 {
				t.Fatalf("non-GET request made %d database probes", calls)
			}
			var envelope ErrorEnvelope
			if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
				t.Fatal(err)
			}
			if envelope.Error.Code != "METHOD_NOT_ALLOWED" || envelope.Error.Message != "method not allowed" || envelope.Error.Details != nil {
				t.Fatalf("unexpected method error: %#v", envelope)
			}
			if envelope.Error.RequestID == "" || envelope.Error.RequestID != response.Header().Get("X-Request-ID") {
				t.Fatal("method error lost request ID")
			}
		})
	}
}
