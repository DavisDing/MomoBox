package platform_test

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/momobox/backend/internal/platform"
)

var exampleSecuritySecrets = []struct {
	name  string
	value string
}{
	{"JWT_SECRET", "replace-with-at-least-32-random-bytes"},
	{"REFRESH_TOKEN_PEPPER", "replace-with-long-random-secret"},
	{"HA_TOKEN_ENCRYPTION_KEY", "change-this-key-to-exactly-32byt"},
}

func securityConfig() platform.Config {
	return platform.Config{
		AppEnv:               "production",
		HTTPAddr:             "127.0.0.1:8080",
		JWTSecret:            strings.Repeat("j", 32),
		RefreshTokenPepper:   strings.Repeat("p", 32),
		HATokenEncryptionKey: strings.Repeat("h", 32),
		RegistrationMode:     platform.DefaultRegistrationMode,
		AccessTokenTTL:       platform.DefaultAccessTokenTTL,
		RefreshTokenTTL:      platform.DefaultRefreshTokenTTL,
		MaxRequestBodyBytes:  platform.DefaultMaxRequestBodyBytes,
		SchemaVersion:        platform.DefaultSchemaVersion,
		SyncProtocolVersion:  platform.DefaultSyncProtocolVersion,
	}
}

func setSecuritySecret(cfg *platform.Config, name, value string) {
	switch name {
	case "JWT_SECRET":
		cfg.JWTSecret = value
	case "REFRESH_TOKEN_PEPPER":
		cfg.RefreshTokenPepper = value
	case "HA_TOKEN_ENCRYPTION_KEY":
		cfg.HATokenEncryptionKey = value
	}
}

func TestProductionRejectsKnownExampleSecrets(t *testing.T) {
	// Reject all known sample secrets in every secret field, including copied
	// whitespace that can make a too-short placeholder pass a byte-length check.
	for _, field := range exampleSecuritySecrets {
		for _, sample := range exampleSecuritySecrets {
			for _, appEnv := range []string{"production", " Production "} {
				for _, padding := range []string{"", " "} {
					t.Run(field.name+"/"+sample.name+"/"+appEnv+"/padding="+padding, func(t *testing.T) {
						cfg := securityConfig()
						cfg.AppEnv = appEnv
						setSecuritySecret(&cfg, field.name, padding+sample.value+padding)
						err := cfg.Validate()
						if err == nil || !strings.Contains(err.Error(), field.name) || !strings.Contains(err.Error(), "placeholder") {
							t.Fatalf("example secret was not explicitly rejected: %v", err)
						}
						if strings.Contains(err.Error(), sample.value) {
							t.Fatal("validation error exposes the secret value")
						}
					})
				}
			}
		}
	}
}

func TestSecurityConfigPreservesValidValues(t *testing.T) {
	for _, appEnv := range []string{"production", "development", "test", ""} {
		t.Run(appEnv, func(t *testing.T) {
			cfg := securityConfig()
			cfg.AppEnv = appEnv
			cfg.JWTSecret = " " + strings.Repeat("j", 64) + " "
			cfg.RefreshTokenPepper = " " + strings.Repeat("p", 64) + " "
			cfg.HATokenEncryptionKey = " " + strings.Repeat("h", 30) + " "
			before := cfg
			if err := cfg.Validate(); err != nil {
				t.Fatalf("valid existing config rejected: %v", err)
			}
			if cfg != before {
				t.Fatal("validation changed secret bytes or config fields")
			}
		})
	}
}

func TestNonProductionRetainsExistingExampleValidation(t *testing.T) {
	cfg := securityConfig()
	cfg.AppEnv = "development"
	cfg.JWTSecret = exampleSecuritySecrets[0].value
	// The sample pepper is 31 bytes; one padding byte demonstrates the
	// existing length-valid behavior. The sample HA key is already 32 bytes.
	cfg.RefreshTokenPepper = " " + exampleSecuritySecrets[1].value
	cfg.HATokenEncryptionKey = exampleSecuritySecrets[2].value
	if err := cfg.Validate(); err != nil {
		t.Fatalf("development validation changed: %v", err)
	}
}

func TestSecurityConfigRetainsByteLengthValidation(t *testing.T) {
	for _, test := range []struct {
		name  string
		value string
	}{
		{"JWT_SECRET", ""},
		{"JWT_SECRET", strings.Repeat("j", 31)},
		{"REFRESH_TOKEN_PEPPER", ""},
		{"REFRESH_TOKEN_PEPPER", strings.Repeat("p", 31)},
		{"HA_TOKEN_ENCRYPTION_KEY", ""},
		{"HA_TOKEN_ENCRYPTION_KEY", strings.Repeat("h", 31)},
		{"HA_TOKEN_ENCRYPTION_KEY", strings.Repeat("h", 33)},
	} {
		t.Run(test.name+"/"+test.value, func(t *testing.T) {
			cfg := securityConfig()
			setSecuritySecret(&cfg, test.name, test.value)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), test.name) {
				t.Fatalf("invalid secret length accepted: %v", err)
			}
		})
	}
}

func setSecurityConfigEnv(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		"HTTP_ADDR", "DATABASE_URL", "REGISTRATION_MODE", "ACCESS_TOKEN_TTL",
		"REFRESH_TOKEN_TTL", "MAX_REQUEST_BODY_BYTES", "LOG_LEVEL", "APP_VERSION",
		"API_VERSION", "SCHEMA_VERSION", "SYNC_PROTOCOL_VERSION",
	} {
		t.Setenv(name, "")
	}
	t.Setenv("APP_ENV", "production")
	t.Setenv("JWT_SECRET", strings.Repeat("j", 64))
	t.Setenv("REFRESH_TOKEN_PEPPER", strings.Repeat("p", 64))
	t.Setenv("HA_TOKEN_ENCRYPTION_KEY", strings.Repeat("h", 32))
}

func TestLoadConfigRejectsProductionExampleSecrets(t *testing.T) {
	for _, sample := range exampleSecuritySecrets {
		t.Run(sample.name, func(t *testing.T) {
			setSecurityConfigEnv(t)
			t.Setenv(sample.name, sample.value)
			_, err := platform.LoadConfig()
			if err == nil || !strings.Contains(err.Error(), sample.name) || !strings.Contains(err.Error(), "placeholder") {
				t.Fatalf("LoadConfig accepted production sample: %v", err)
			}
		})
	}
}

func TestLoadConfigPreservesSecretsAndDefaults(t *testing.T) {
	setSecurityConfigEnv(t)
	jwt := " " + strings.Repeat("j", 64) + " "
	pepper := " " + strings.Repeat("p", 64) + " "
	haKey := " " + strings.Repeat("h", 30) + " "
	t.Setenv("JWT_SECRET", jwt)
	t.Setenv("REFRESH_TOKEN_PEPPER", pepper)
	t.Setenv("HA_TOKEN_ENCRYPTION_KEY", haKey)
	cfg, err := platform.LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.JWTSecret != jwt || cfg.RefreshTokenPepper != pepper || cfg.HATokenEncryptionKey != haKey {
		t.Fatal("LoadConfig changed secret bytes")
	}
	if cfg.SchemaVersion != platform.DefaultSchemaVersion || cfg.SyncProtocolVersion != platform.DefaultSyncProtocolVersion {
		t.Fatal("schema or sync protocol defaults changed")
	}
	if cfg.AccessTokenTTL != 15*time.Minute || cfg.RefreshTokenTTL != 30*24*time.Hour {
		t.Fatal("token TTL defaults changed")
	}
}

func TestKnownExampleSecretsMatchDeploymentTemplate(t *testing.T) {
	data, err := os.ReadFile("../../../deploy/nas/.env.example")
	if os.IsNotExist(err) {
		// The backend is also built from an independent Docker context.
		t.Skip("deployment template is not present in a backend-only checkout")
	}
	if err != nil {
		t.Fatal(err)
	}
	values := make(map[string]string)
	for _, line := range strings.Split(string(data), "\n") {
		if name, value, ok := strings.Cut(line, "="); ok {
			values[name] = value
		}
	}
	for _, sample := range exampleSecuritySecrets {
		if values[sample.name] != sample.value {
			t.Fatalf("%s deployment sample changed; review the production denylist", sample.name)
		}
	}
}
