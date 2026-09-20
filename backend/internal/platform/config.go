package platform

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultHTTPAddr            = "0.0.0.0:8080"
	DefaultRegistrationMode    = "first_setup"
	DefaultAccessTokenTTL      = 15 * time.Minute
	DefaultRefreshTokenTTL     = 30 * 24 * time.Hour
	DefaultMaxRequestBodyBytes = 1 << 20
	DefaultAppVersion          = "0.1.0"
	DefaultAPIVersion          = "v1"
	DefaultSchemaVersion       = 1
	DefaultSyncProtocolVersion = 1
)

type Config struct {
	AppEnv               string
	HTTPAddr             string
	DatabaseURL          string
	JWTSecret            string
	RefreshTokenPepper   string
	HATokenEncryptionKey string
	RegistrationMode     string
	AccessTokenTTL       time.Duration
	RefreshTokenTTL      time.Duration
	MaxRequestBodyBytes  int64
	LogLevel             string
	AppVersion           string
	APIVersion           string
	SchemaVersion        int
	SyncProtocolVersion  int
}

func LoadConfig() (Config, error) {
	cfg := Config{
		AppEnv:               envOrDefault("APP_ENV", "development"),
		HTTPAddr:             envOrDefault("HTTP_ADDR", DefaultHTTPAddr),
		DatabaseURL:          strings.TrimSpace(os.Getenv("DATABASE_URL")),
		JWTSecret:            os.Getenv("JWT_SECRET"),
		RefreshTokenPepper:   os.Getenv("REFRESH_TOKEN_PEPPER"),
		HATokenEncryptionKey: os.Getenv("HA_TOKEN_ENCRYPTION_KEY"),
		RegistrationMode:     envOrDefault("REGISTRATION_MODE", DefaultRegistrationMode),
		AccessTokenTTL:       DefaultAccessTokenTTL,
		RefreshTokenTTL:      DefaultRefreshTokenTTL,
		MaxRequestBodyBytes:  DefaultMaxRequestBodyBytes,
		LogLevel:             envOrDefault("LOG_LEVEL", "info"),
		AppVersion:           envOrDefault("APP_VERSION", DefaultAppVersion),
		APIVersion:           envOrDefault("API_VERSION", DefaultAPIVersion),
		SchemaVersion:        DefaultSchemaVersion,
		SyncProtocolVersion:  DefaultSyncProtocolVersion,
	}

	var err error
	if cfg.AccessTokenTTL, err = durationEnv("ACCESS_TOKEN_TTL", cfg.AccessTokenTTL); err != nil {
		return Config{}, err
	}
	if cfg.RefreshTokenTTL, err = durationEnv("REFRESH_TOKEN_TTL", cfg.RefreshTokenTTL); err != nil {
		return Config{}, err
	}
	if raw := strings.TrimSpace(os.Getenv("MAX_REQUEST_BODY_BYTES")); raw != "" {
		cfg.MaxRequestBodyBytes, err = strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return Config{}, fmt.Errorf("MAX_REQUEST_BODY_BYTES: %w", err)
		}
	}
	if raw := strings.TrimSpace(os.Getenv("SCHEMA_VERSION")); raw != "" {
		cfg.SchemaVersion, err = strconv.Atoi(raw)
		if err != nil {
			return Config{}, fmt.Errorf("SCHEMA_VERSION: %w", err)
		}
	}
	if raw := strings.TrimSpace(os.Getenv("SYNC_PROTOCOL_VERSION")); raw != "" {
		cfg.SyncProtocolVersion, err = strconv.Atoi(raw)
		if err != nil {
			return Config{}, fmt.Errorf("SYNC_PROTOCOL_VERSION: %w", err)
		}
	}
	return cfg, cfg.Validate()
}

func (c Config) Validate() error {
	if strings.TrimSpace(c.HTTPAddr) == "" {
		return errors.New("HTTP_ADDR must not be empty")
	}
	if _, _, err := net.SplitHostPort(c.HTTPAddr); err != nil {
		return fmt.Errorf("HTTP_ADDR must be host:port: %w", err)
	}
	if c.DatabaseURL != "" {
		u, err := url.Parse(c.DatabaseURL)
		if err != nil || u.Scheme != "postgres" && u.Scheme != "postgresql" {
			return errors.New("DATABASE_URL must be a postgres:// or postgresql:// URL")
		}
	}
	if c.JWTSecret == "" {
		return errors.New("JWT_SECRET must not be empty")
	}
	if len(c.JWTSecret) < 32 {
		return errors.New("JWT_SECRET must be at least 32 bytes")
	}
	if c.RefreshTokenPepper == "" {
		return errors.New("REFRESH_TOKEN_PEPPER must not be empty")
	}
	if len(c.RefreshTokenPepper) < 32 {
		return errors.New("REFRESH_TOKEN_PEPPER must be at least 32 bytes")
	}
	if c.HATokenEncryptionKey == "" {
		return errors.New("HA_TOKEN_ENCRYPTION_KEY must not be empty")
	}
	if len(c.HATokenEncryptionKey) != 32 {
		return errors.New("HA_TOKEN_ENCRYPTION_KEY must be exactly 32 bytes")
	}
	if c.RegistrationMode != "first_setup" && c.RegistrationMode != "invite_only" && c.RegistrationMode != "open" {
		return fmt.Errorf("REGISTRATION_MODE must be first_setup, invite_only, or open")
	}
	if c.AccessTokenTTL <= 0 || c.RefreshTokenTTL <= 0 {
		return errors.New("token TTLs must be positive")
	}
	if c.RefreshTokenTTL < c.AccessTokenTTL {
		return errors.New("REFRESH_TOKEN_TTL must not be shorter than ACCESS_TOKEN_TTL")
	}
	if c.MaxRequestBodyBytes <= 0 {
		return errors.New("MAX_REQUEST_BODY_BYTES must be positive")
	}
	if c.SchemaVersion < 1 || c.SyncProtocolVersion < 1 {
		return errors.New("schema and sync protocol versions must be positive")
	}
	return nil
}

func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func durationEnv(name string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	duration, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", name, err)
	}
	return duration, nil
}
