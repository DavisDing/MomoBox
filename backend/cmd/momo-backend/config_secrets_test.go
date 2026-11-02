package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadOnlyCommandsDoNotInitializeDeploymentSecrets(t *testing.T) {
	for _, command := range []struct {
		name string
		run  func(context.Context) error
	}{
		{"healthcheck", healthcheck},
		{"schema-check", schemaCheck},
	} {
		t.Run(command.name, func(t *testing.T) {
			directory := filepath.Join(t.TempDir(), "data")
			for _, name := range []string{
				"JWT_SECRET", "REFRESH_TOKEN_PEPPER", "HA_TOKEN_ENCRYPTION_KEY",
				"HTTP_ADDR", "DATABASE_URL", "REGISTRATION_MODE", "ACCESS_TOKEN_TTL",
				"REFRESH_TOKEN_TTL", "MAX_REQUEST_BODY_BYTES", "SCHEMA_VERSION", "SYNC_PROTOCOL_VERSION",
			} {
				t.Setenv(name, "")
			}
			t.Setenv("MOMO_DATA_DIR", directory)
			err := command.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), "persisted secrets are missing") {
				t.Fatalf("command did not stop before network access: %v", err)
			}
			if _, err := os.Stat(directory); !os.IsNotExist(err) {
				t.Fatal("read-only command created persistent state")
			}
		})
	}
}
