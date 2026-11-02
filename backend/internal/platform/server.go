package platform

import (
	"context"
	"github.com/momobox/backend/internal/processing"
	"net/http"
	"time"
)

// Bound database probes independently of HTTP write and container timeouts.
const healthDatabaseTimeout = 2 * time.Second

type Server struct {
	HTTPServer      *http.Server
	DB              DB
	Config          Config
	SchemaReadiness func(context.Context) error
}

func NewHTTPServer(cfg Config, db DB) *Server {
	return NewHTTPServerWithRoutes(cfg, db, nil)
}

// NewHTTPServerWithRoutes keeps platform endpoints in this package while
// allowing the composition root to mount the independently tested business
// HTTP adapter once concrete repositories are wired. A nil business handler
// deliberately preserves the explicit NOT_IMPLEMENTED response.
func NewHTTPServerWithRoutes(cfg Config, db DB, businessRoutes http.Handler) *Server {
	mux := http.NewServeMux()
	platform := &Server{Config: cfg, DB: db}
	mux.Handle("/api/v1/health", RequestIDMiddleware(http.HandlerFunc(platform.healthHandler)))
	mux.Handle("/api/v1/version", RequestIDMiddleware(http.HandlerFunc(platform.versionHandler)))
	mux.Handle("/api/v1/capabilities", RequestIDMiddleware(http.HandlerFunc(platform.capabilitiesHandler)))
	if businessRoutes != nil {
		mux.Handle("/api/v1/", businessRoutes)
	} else {
		mux.Handle("/api/v1/", RequestIDMiddleware(http.HandlerFunc(NotImplementedHandler)))
	}
	platform.HTTPServer = &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           RequestIDMiddleware(RequestLogMiddleware(nil, requestLimitMiddleware(cfg.MaxRequestBodyBytes, RouteTemplateHandler(mux)))),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      120 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	return platform
}

func (s *Server) Shutdown(ctx context.Context) error {
	if s.HTTPServer == nil {
		return nil
	}
	return s.HTTPServer.Shutdown(ctx)
}

func (s *Server) healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		WriteAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", nil)
		return
	}
	// Inherit earlier deadlines and cancellation; release the timer even when
	// PingContext succeeds. Production also checks this image's migration ledger.
	ctx, cancel := context.WithTimeout(r.Context(), healthDatabaseTimeout)
	defer cancel()
	status, database := "ok", "ok"
	if s.DB == nil || s.DB.PingContext(ctx) != nil {
		status, database = "degraded", "unavailable"
	} else if s.SchemaReadiness != nil && s.SchemaReadiness(ctx) != nil {
		status, database = "degraded", "unavailable"
	}
	code := http.StatusOK
	if database == "unavailable" {
		code = http.StatusServiceUnavailable
	}
	WriteJSON(w, code, map[string]string{"status": status, "database": database})
}

func (s *Server) versionHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		WriteAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", nil)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"app_version": s.Config.AppVersion, "api_version": s.Config.APIVersion, "schema_version": s.Config.SchemaVersion,
	})
}

func (s *Server) capabilitiesHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		WriteAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "method not allowed", nil)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"schema_version": s.Config.SchemaVersion, "sync_protocol_version": s.Config.SyncProtocolVersion,
		"media_upload": true, "backend_ocr": true, "backend_ai": len(processing.AIFromEnv().Endpoints) > 0, "operation_history": true, "ai_proxy": true, "ollama_embedded": false,
		"inventory_commands": true, "home_assistant": true,
	})
}

func requestLimitMiddleware(maxBytes int64, next http.Handler) http.Handler {
	if maxBytes <= 0 {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
		next.ServeHTTP(w, r)
	})
}
