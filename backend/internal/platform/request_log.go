package platform

import (
	"log/slog"
	"net/http"
	"time"
)

type statusWriter struct {
	http.ResponseWriter
	status int
	route  string
}

func (w *statusWriter) SetRequestRoute(route string) { w.route = route }
func (w *statusWriter) Unwrap() http.ResponseWriter  { return w.ResponseWriter }
func (w *statusWriter) WriteHeader(status int) {
	if status >= 100 && status < 200 && status != http.StatusSwitchingProtocols {
		w.ResponseWriter.WriteHeader(status)
		return
	}
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
func (w *statusWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

// RequestLogMiddleware logs route templates and status only. It deliberately
// omits URL/path/query, body, bearer headers and all business payloads.
func RequestLogMiddleware(logger *slog.Logger, next http.Handler) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		writer := &statusWriter{ResponseWriter: w}
		defer func() {
			recovered := recover()
			status := writer.status
			errorType := ""
			if recovered != nil {
				errorType = "panic"
				if status == 0 {
					status = http.StatusInternalServerError
				}
			}
			if status == 0 {
				status = http.StatusOK
			}
			if errorType == "" && status >= 500 {
				errorType = "server_error"
			} else if errorType == "" && status >= 400 {
				errorType = "client_error"
			}
			route := writer.route
			if route == "" {
				route = "unmatched"
			}
			logger.InfoContext(r.Context(), "http_request", "request_id", RequestIDFromContext(r.Context()), "route", route, "status", status, "duration_ms", time.Since(started).Milliseconds(), "error_type", errorType)
			if recovered != nil {
				panic(recovered)
			}
		}()
		next.ServeHTTP(writer, r)
	})
}

// RouteTemplateHandler uses only registered mux patterns, never user paths.
// It forwards the selected template to the outer logging response writer.
func RouteTemplateHandler(mux *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if sink, ok := w.(interface{ SetRequestRoute(string) }); ok {
			_, pattern := mux.Handler(r)
			sink.SetRequestRoute(pattern)
		}
		mux.ServeHTTP(w, r)
	})
}
