package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"
)

const httpShutdownTimeout = 10 * time.Second

type httpServerLifecycle interface {
	ListenAndServe() error
	Shutdown(context.Context) error
	Close() error
}

// serveHTTP waits for drained requests before its caller can close the database.
// A listener failure also initiates cleanup, without waiting for a future signal.
func serveHTTP(ctx context.Context, server httpServerLifecycle, shutdownTimeout time.Duration) error {
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- server.ListenAndServe()
	}()

	var serveErr error
	serveStopped := false
	select {
	case <-ctx.Done():
	case serveErr = <-serveResult:
		serveStopped = true
	}

	// The signal context is already canceled on normal exit. Give existing
	// requests a fresh, bounded context, including on early listener failure.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	var result error
	if err := server.Shutdown(shutdownCtx); err != nil {
		result = fmt.Errorf("shutdown HTTP: %w", err)
		if err := server.Close(); err != nil {
			result = errors.Join(result, fmt.Errorf("close HTTP: %w", err))
		}
	}

	if !serveStopped {
		select {
		case serveErr = <-serveResult:
		case <-shutdownCtx.Done():
			// Both channels may be ready after a shutdown timeout. Preserve
			// an already available listener error rather than losing it.
			select {
			case serveErr = <-serveResult:
			default:
				result = errors.Join(result, fmt.Errorf("wait for HTTP exit: %w", shutdownCtx.Err()))
			}
		}
	}
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		result = errors.Join(result, fmt.Errorf("serve HTTP: %w", serveErr))
	}
	return result
}
