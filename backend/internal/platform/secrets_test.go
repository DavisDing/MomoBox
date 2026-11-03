package platform_test

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/platform"
	"github.com/momobox/backend/internal/securetoken"
)

func automaticSecretsEnv(t *testing.T) string {
	t.Helper()
	setSecurityConfigEnv(t)
	for _, name := range []string{"JWT_SECRET", "REFRESH_TOKEN_PEPPER", "HA_TOKEN_ENCRYPTION_KEY"} {
		t.Setenv(name, "")
	}
	directory := filepath.Join(t.TempDir(), "data")
	t.Setenv("MOMO_DATA_DIR", directory)
	return directory
}

func TestAutomaticSecretsSurviveRestartAndProtectExistingCredentials(t *testing.T) {
	directory := automaticSecretsEnv(t)
	first, err := platform.LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "secrets.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("secret file is not private: %v", err)
	}
	if len(first.JWTSecret) != 64 || len(first.RefreshTokenPepper) != 64 || len(first.HATokenEncryptionKey) != 32 || first.JWTSecret == first.RefreshTokenPepper {
		t.Fatal("generated secret sizes or independence are incorrect")
	}
	second, err := platform.LoadConfigReadOnly()
	if err != nil || second != first {
		t.Fatalf("restart did not preserve config: %v", err)
	}
	if restarted, err := platform.LoadConfig(); err != nil || restarted != first {
		t.Fatalf("normal startup did not reuse secrets: %v", err)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("restart modified persisted secrets")
	}
	t.Setenv("HTTP_ADDR", "invalid")
	if _, err := platform.LoadConfig(); err == nil || !strings.Contains(err.Error(), "HTTP_ADDR") {
		t.Fatal("non-secret config error was misreported as secret file corruption")
	}
	t.Setenv("HTTP_ADDR", "")
	ctx := context.Background()
	cipher, err := securetoken.NewAESGCM([]byte(first.HATokenEncryptionKey))
	if err != nil {
		t.Fatal(err)
	}
	sealed, version, err := cipher.Encrypt(ctx, "existing-ha-token")
	if err != nil {
		t.Fatal(err)
	}
	reloaded, err := securetoken.NewAESGCM([]byte(second.HATokenEncryptionKey))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := reloaded.Decrypt(ctx, sealed, version)
	if err != nil || plain != "existing-ha-token" {
		t.Fatalf("HA credential failed after reload: %v", err)
	}
	firstHash := (auth.HMACRefreshTokenHasher{Pepper: []byte(first.RefreshTokenPepper)}).Hash("existing-refresh-token")
	secondHash := (auth.HMACRefreshTokenHasher{Pepper: []byte(second.RefreshTokenPepper)}).Hash("existing-refresh-token")
	if firstHash != secondHash {
		t.Fatal("refresh token hashes changed after reload")
	}
	now := time.Now().UTC()
	token, err := (auth.HMACJWTIssuer{Secret: []byte(first.JWTSecret)}).Issue(auth.AccessTokenClaims{UserID: "existing-user", IssuedAt: now, ExpiresAt: now.Add(time.Hour)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := (auth.HMACJWTIssuer{Secret: []byte(second.JWTSecret)}).Verify(token, now); err != nil {
		t.Fatalf("access token failed after reload: %v", err)
	}
}

func TestConcurrentAutomaticSecretsUseOneIdentity(t *testing.T) {
	directory := automaticSecretsEnv(t)
	const count = 24
	configs := make([]platform.Config, count)
	errors := make([]error, count)
	var group sync.WaitGroup
	start := make(chan struct{})
	for i := range configs {
		group.Add(1)
		go func(i int) {
			defer group.Done()
			<-start
			configs[i], errors[i] = platform.LoadConfig()
		}(i)
	}
	close(start)
	group.Wait()
	for i, err := range errors {
		if err != nil {
			t.Fatalf("initializer %d failed: %v", i, err)
		}
		if configs[i] != configs[0] {
			t.Fatal("concurrent initializers received different identities")
		}
	}
	files, err := os.ReadDir(directory)
	if err != nil || len(files) != 1 || files[0].Name() != "secrets.json" {
		t.Fatalf("temporary files left behind: %v", err)
	}
}

func TestExplicitSecretsBypassStorageAndPartialInitializationPreservesBytes(t *testing.T) {
	directory := automaticSecretsEnv(t)
	jwt := " " + strings.Repeat("j", 40) + " "
	t.Setenv("JWT_SECRET", jwt)
	first, err := platform.LoadConfig()
	if err != nil || first.JWTSecret != jwt {
		t.Fatalf("partial explicit configuration failed: %v", err)
	}
	t.Setenv("JWT_SECRET", "")
	loaded, err := platform.LoadConfig()
	if err != nil || loaded != first {
		t.Fatalf("initial explicit key was not persisted: %v", err)
	}
	path := filepath.Join(directory, "secrets.json")
	before, _ := os.ReadFile(path)
	t.Setenv("JWT_SECRET", strings.Repeat("x", 64))
	overridden, err := platform.LoadConfig()
	if err != nil || overridden.JWTSecret != strings.Repeat("x", 64) || overridden.RefreshTokenPepper != first.RefreshTokenPepper {
		t.Fatalf("explicit override failed: %v", err)
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(before, after) {
		t.Fatal("override silently rotated persisted keys")
	}
	t.Setenv("REFRESH_TOKEN_PEPPER", first.RefreshTokenPepper)
	t.Setenv("HA_TOKEN_ENCRYPTION_KEY", first.HATokenEncryptionKey)
	// Fully explicit legacy deployments must work without any data directory.
	t.Setenv("MOMO_DATA_DIR", filepath.Join(path, "not-a-directory"))
	if _, err := platform.LoadConfig(); err != nil {
		t.Fatalf("legacy deployment now needs writable storage: %v", err)
	}
}

func TestAutomaticSecretsFailWithoutReplacingInvalidFiles(t *testing.T) {
	for _, kind := range []string{"malformed", "missing-field", "version", "trailing", "public", "symlink", "directory", "oversized"} {
		t.Run(kind, func(t *testing.T) {
			directory := automaticSecretsEnv(t)
			if _, err := platform.LoadConfig(); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(directory, "secrets.json")
			data, _ := os.ReadFile(path)
			switch kind {
			case "malformed":
				data = []byte(`{"jwt_secret":"sensitive-invalid-value"`)
			case "missing-field", "version":
				var document map[string]any
				if err := json.Unmarshal(data, &document); err != nil {
					t.Fatal(err)
				}
				if kind == "missing-field" {
					delete(document, "jwt_secret")
					// An override must not hide an incomplete persisted identity.
					t.Setenv("JWT_SECRET", strings.Repeat("x", 64))
				} else {
					document["version"] = 2
				}
				data, _ = json.Marshal(document)
			case "trailing":
				data = append(data, []byte(` {}`)...)
			case "oversized":
				data = bytes.Repeat([]byte(" "), 17000)
			}
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "public":
				if err := os.Chmod(path, 0644); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Rename(path, path+".original"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(path+".original", path); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatal(err)
				}
			}
			_, err := platform.LoadConfig()
			if err == nil || strings.Contains(err.Error(), "sensitive-invalid-value") {
				t.Fatal("invalid secret file was accepted or leaked")
			}
			if kind != "directory" {
				after, err := os.ReadFile(path)
				if err != nil || !bytes.Equal(data, after) {
					t.Fatal("invalid file was overwritten")
				}
			}
		})
	}
}

func TestAutomaticSecretsDoNotWriteForInvalidConfigOrReadOnlyChecks(t *testing.T) {
	directory := automaticSecretsEnv(t)
	if _, err := platform.LoadConfigReadOnly(); err == nil {
		t.Fatal("read-only check initialized missing secrets")
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatal("read-only check created data directory")
	}
	t.Setenv("HTTP_ADDR", "invalid")
	if _, err := platform.LoadConfig(); err == nil {
		t.Fatal("invalid config accepted")
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatal("invalid config persisted secrets")
	}
	t.Setenv("HTTP_ADDR", "")
	t.Setenv("JWT_SECRET", "short")
	if _, err := platform.LoadConfig(); err == nil {
		t.Fatal("invalid explicit key accepted")
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatal("invalid explicit key persisted secrets")
	}
}

func TestAutomaticSecretsRejectUnwritableStorage(t *testing.T) {
	directory := automaticSecretsEnv(t)
	if err := os.Mkdir(directory, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(directory, 0700) })
	if os.Geteuid() == 0 {
		t.Skip("root bypasses directory write permissions")
	}
	if _, err := platform.LoadConfig(); err == nil {
		t.Fatal("unwritable storage was accepted")
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 0 {
		t.Fatal("failed initialization left secret files")
	}
}
