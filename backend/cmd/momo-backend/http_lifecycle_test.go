package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

type httpLifecycleStub struct {
	listen   func() error
	shutdown func(context.Context) error
	close    func() error
}

func (s httpLifecycleStub) ListenAndServe() error              { return s.listen() }
func (s httpLifecycleStub) Shutdown(ctx context.Context) error { return s.shutdown(ctx) }
func (s httpLifecycleStub) Close() error                       { return s.close() }

func runHTTPLifecycle(ctx context.Context, server httpServerLifecycle, timeout time.Duration) <-chan error {
	result := make(chan error, 1)
	go func() { result <- serveHTTP(ctx, server, timeout) }()
	return result
}

func awaitHTTPLifecycle(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result:
		return err
	case <-time.After(2 * time.Second):
		t.Fatal("HTTP lifecycle did not finish")
		return nil
	}
}

func awaitHTTPEvent(t *testing.T, event <-chan struct{}) {
	t.Helper()
	select {
	case <-event:
	case <-time.After(2 * time.Second):
		t.Fatal("HTTP lifecycle event did not arrive")
	}
}

func TestServeHTTPWaitsForShutdownAfterListenerStops(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listenStarted := make(chan struct{})
	listenerStopped := make(chan struct{})
	shutdownStarted := make(chan context.Context, 1)
	finishShutdown := make(chan struct{})
	defer close(finishShutdown)
	server := httpLifecycleStub{
		listen: func() error {
			close(listenStarted)
			<-listenerStopped
			return http.ErrServerClosed
		},
		shutdown: func(ctx context.Context) error {
			close(listenerStopped)
			shutdownStarted <- ctx
			<-finishShutdown
			return nil
		},
		close: func() error {
			t.Error("successful shutdown must not force-close requests")
			return nil
		},
	}
	result := runHTTPLifecycle(ctx, server, 5*time.Second)
	awaitHTTPEvent(t, listenStarted)
	cancel()

	var shutdownCtx context.Context
	select {
	case shutdownCtx = <-shutdownStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("shutdown did not start")
	}
	if shutdownCtx.Err() != nil {
		t.Fatalf("shutdown inherited signal cancellation: %v", shutdownCtx.Err())
	}
	if _, ok := shutdownCtx.Deadline(); !ok {
		t.Fatal("shutdown has no deadline")
	}
	select {
	case err := <-result:
		t.Fatalf("returned before shutdown finished: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	finishShutdown <- struct{}{}
	if err := awaitHTTPLifecycle(t, result); err != nil {
		t.Fatalf("graceful shutdown failed: %v", err)
	}
	if !errors.Is(shutdownCtx.Err(), context.Canceled) {
		t.Fatalf("shutdown context was not released: %v", shutdownCtx.Err())
	}
}

func TestServeHTTPListenerExitDoesNotWaitForSignal(t *testing.T) {
	listenFailure := errors.New("address already in use")
	for _, test := range []struct {
		name string
		err  error
	}{
		{name: "listener failure", err: listenFailure},
		{name: "already closed", err: http.ErrServerClosed},
		{name: "normal return", err: nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			shutdownCalled := false
			server := httpLifecycleStub{
				listen: func() error { return test.err },
				shutdown: func(ctx context.Context) error {
					shutdownCalled = true
					return ctx.Err()
				},
				close: func() error {
					t.Error("successful cleanup must not force-close")
					return nil
				},
			}
			err := awaitHTTPLifecycle(t, runHTTPLifecycle(context.Background(), server, time.Second))
			if !shutdownCalled {
				t.Fatal("listener exit skipped cleanup")
			}
			if test.err == listenFailure {
				if !errors.Is(err, listenFailure) {
					t.Fatalf("listener error lost: %v", err)
				}
			} else if err != nil {
				t.Fatalf("normal listener exit failed: %v", err)
			}
		})
	}
}

func TestServeHTTPPreservesServeShutdownAndCloseErrors(t *testing.T) {
	listenFailure := errors.New("listener failed")
	shutdownFailure := errors.New("shutdown failed")
	closeFailure := errors.New("close failed")
	server := httpLifecycleStub{
		listen:   func() error { return listenFailure },
		shutdown: func(context.Context) error { return shutdownFailure },
		close:    func() error { return closeFailure },
	}
	err := awaitHTTPLifecycle(t, runHTTPLifecycle(context.Background(), server, time.Second))
	for _, want := range []error{listenFailure, shutdownFailure, closeFailure} {
		if !errors.Is(err, want) {
			t.Errorf("error %v was lost: %v", want, err)
		}
	}
}

func TestServeHTTPShutdownDeadlineForcesClose(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listenStarted := make(chan struct{})
	closed := make(chan struct{})
	server := httpLifecycleStub{
		listen: func() error {
			close(listenStarted)
			<-closed
			return http.ErrServerClosed
		},
		shutdown: func(ctx context.Context) error {
			<-ctx.Done()
			return ctx.Err()
		},
		close: func() error {
			close(closed)
			return nil
		},
	}
	result := runHTTPLifecycle(ctx, server, 20*time.Millisecond)
	awaitHTTPEvent(t, listenStarted)
	cancel()
	if err := awaitHTTPLifecycle(t, result); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("shutdown deadline lost: %v", err)
	}
	awaitHTTPEvent(t, closed)
}

func TestServeHTTPCancellationPreservesLateListenerError(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listenStarted := make(chan struct{})
	stopListening := make(chan struct{})
	listenFailure := errors.New("listener failed during shutdown")
	server := httpLifecycleStub{
		listen: func() error {
			close(listenStarted)
			<-stopListening
			return listenFailure
		},
		shutdown: func(context.Context) error {
			close(stopListening)
			return nil
		},
		close: func() error { return nil },
	}
	result := runHTTPLifecycle(ctx, server, 5*time.Second)
	awaitHTTPEvent(t, listenStarted)
	cancel()
	if err := awaitHTTPLifecycle(t, result); !errors.Is(err, listenFailure) {
		t.Fatalf("late listener error lost: %v", err)
	}
}

func TestServeHTTPPreservesListenerErrorOnShutdownDeadline(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listenStarted := make(chan struct{})
	stopListening := make(chan struct{})
	listenFailure := errors.New("listener failed while draining")
	server := httpLifecycleStub{
		listen: func() error {
			close(listenStarted)
			<-stopListening
			return listenFailure
		},
		shutdown: func(ctx context.Context) error {
			close(stopListening)
			<-ctx.Done()
			return ctx.Err()
		},
		close: func() error { return nil },
	}
	result := runHTTPLifecycle(ctx, server, 100*time.Millisecond)
	awaitHTTPEvent(t, listenStarted)
	cancel()
	err := awaitHTTPLifecycle(t, result)
	if !errors.Is(err, listenFailure) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("listener failure or shutdown deadline lost: %v", err)
	}
}

func TestServeHTTPDoesNotWaitIndefinitelyForListener(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	finishListen := make(chan struct{})
	defer close(finishListen)
	server := httpLifecycleStub{
		listen: func() error {
			<-finishListen
			return http.ErrServerClosed
		},
		shutdown: func(context.Context) error { return nil },
		close:    func() error { return nil },
	}
	if err := awaitHTTPLifecycle(t, runHTTPLifecycle(ctx, server, 20*time.Millisecond)); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("listener wait was not bounded: %v", err)
	}
}

// Use an already bound ephemeral listener to test real request draining without
// a database or a race between choosing a port and starting ListenAndServe.
type drainingHTTPServer struct {
	*http.Server
	listener        net.Listener
	shutdownStarted chan struct{}
}

func (s drainingHTTPServer) ListenAndServe() error { return s.Serve(s.listener) }
func (s drainingHTTPServer) Shutdown(ctx context.Context) error {
	close(s.shutdownStarted)
	return s.Server.Shutdown(ctx)
}

func TestServeHTTPDrainsRealRequestBeforeReturning(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	requestStarted := make(chan struct{})
	finishRequest := make(chan struct{})
	defer close(finishRequest)
	server := drainingHTTPServer{
		Server: &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			close(requestStarted)
			<-finishRequest
			_, _ = io.WriteString(w, "drained")
		})},
		listener:        listener,
		shutdownStarted: make(chan struct{}),
	}
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := runHTTPLifecycle(ctx, server, 5*time.Second)
	clientResult := make(chan error, 1)
	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	go func() {
		response, err := client.Get("http://" + listener.Addr().String())
		if err != nil {
			clientResult <- err
			return
		}
		defer response.Body.Close()
		body, err := io.ReadAll(response.Body)
		if err == nil && string(body) != "drained" {
			err = errors.New("response did not finish draining")
		}
		clientResult <- err
	}()
	awaitHTTPEvent(t, requestStarted)
	cancel()
	awaitHTTPEvent(t, server.shutdownStarted)
	select {
	case err := <-result:
		t.Fatalf("returned with request still active: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	finishRequest <- struct{}{}
	if err := awaitHTTPLifecycle(t, clientResult); err != nil {
		t.Fatalf("active request failed: %v", err)
	}
	if err := awaitHTTPLifecycle(t, result); err != nil {
		t.Fatalf("graceful HTTP exit failed: %v", err)
	}
}
