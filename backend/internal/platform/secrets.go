package platform

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
)

const secretsFilename = "secrets.json"

type persistedSecrets struct {
	Version              int    `json:"version"`
	JWTSecret            string `json:"jwt_secret"`
	RefreshTokenPepper   string `json:"refresh_token_pepper"`
	HATokenEncryptionKey string `json:"ha_token_encryption_key"`
}

func (s persistedSecrets) apply(cfg Config) Config {
	if cfg.JWTSecret == "" {
		cfg.JWTSecret = s.JWTSecret
	}
	if cfg.RefreshTokenPepper == "" {
		cfg.RefreshTokenPepper = s.RefreshTokenPepper
	}
	if cfg.HATokenEncryptionKey == "" {
		cfg.HATokenEncryptionKey = s.HATokenEncryptionKey
	}
	return cfg
}

func resolveSecrets(cfg Config, directory string, initialize bool) (Config, error) {
	// Legacy deployments with all three explicit keys need no writable storage.
	// Environment overrides are never written over an existing secrets file.
	if cfg.JWTSecret != "" && cfg.RefreshTokenPepper != "" && cfg.HATokenEncryptionKey != "" {
		return cfg, cfg.Validate()
	}
	path := filepath.Join(directory, secretsFilename)
	saved, err := readSecrets(path, cfg)
	if err == nil {
		cfg = saved.apply(cfg)
		return cfg, cfg.Validate()
	}
	if !errors.Is(err, os.ErrNotExist) {
		return Config{}, err
	}
	if !initialize {
		return Config{}, errors.New("persisted secrets are missing; initialize with serve or migrate before running read-only checks")
	}
	generated := persistedSecrets{Version: 1}
	for _, field := range []struct {
		value *string
		bytes int
	}{
		{&generated.JWTSecret, 32},
		{&generated.RefreshTokenPepper, 32},
		{&generated.HATokenEncryptionKey, 16},
	} {
		raw := make([]byte, field.bytes)
		if _, err := rand.Read(raw); err != nil {
			return Config{}, errors.New("could not generate deployment secrets")
		}
		*field.value = hex.EncodeToString(raw)
	}
	candidate := generated.apply(cfg)
	if err := candidate.Validate(); err != nil {
		return Config{}, err
	}
	// Preserve any explicitly supplied keys during first partial initialization.
	saved = persistedSecrets{1, candidate.JWTSecret, candidate.RefreshTokenPepper, candidate.HATokenEncryptionKey}
	if err := publishSecrets(directory, path, saved); err != nil {
		return Config{}, err
	}
	// A competing process may have published first. Always use the complete
	// winning file, with this process's explicit environment overrides applied.
	saved, err = readSecrets(path, cfg)
	if err != nil {
		return Config{}, err
	}
	cfg = saved.apply(cfg)
	return cfg, cfg.Validate()
}

func readSecrets(path string, cfg Config) (persistedSecrets, error) {
	invalid := errors.New("persisted secrets are invalid or inaccessible; restore the original secrets.json and check permissions (file must be private and regular)")
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return persistedSecrets{}, os.ErrNotExist
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 16<<10 {
		return persistedSecrets{}, invalid
	}
	file, err := os.Open(path)
	if err != nil {
		return persistedSecrets{}, invalid
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return persistedSecrets{}, invalid
	}
	data, err := io.ReadAll(io.LimitReader(file, (16<<10)+1))
	if err != nil || len(data) > 16<<10 {
		return persistedSecrets{}, invalid
	}
	var saved persistedSecrets
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&saved) != nil || saved.Version != 1 {
		return persistedSecrets{}, invalid
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return persistedSecrets{}, invalid
	}
	// Validate the file itself, even if an environment override masks a field.
	check := cfg
	check.JWTSecret, check.RefreshTokenPepper, check.HATokenEncryptionKey = saved.JWTSecret, saved.RefreshTokenPepper, saved.HATokenEncryptionKey
	if check.validateSecrets() != nil {
		return persistedSecrets{}, invalid
	}
	return saved, nil
}

func publishSecrets(directory, path string, saved persistedSecrets) error {
	failure := errors.New("could not persist deployment secrets; ensure MOMO_DATA_DIR (default /data) is writable and supports atomic hard links")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return failure
	}
	file, err := os.CreateTemp(directory, ".secrets-*")
	if err != nil {
		return failure
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if json.NewEncoder(file).Encode(saved) != nil || file.Sync() != nil {
		return failure
	}
	if file.Close() != nil {
		return failure
	}
	// Link publishes a fully flushed 0600 file without replacing another
	// process's identity. A crash before this step leaves only an unused temp.
	if err := os.Link(file.Name(), path); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return failure
		}
	}
	// Even a losing initializer flushes the directory before using its winner.
	dir, err := os.Open(directory)
	if err != nil {
		return failure
	}
	defer dir.Close()
	if dir.Sync() != nil {
		return failure
	}
	return nil
}
