package securetoken

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
)

// AESGCM encrypts deployment secrets with a 256-bit key. Ciphertexts contain
// a random nonce prefix and are authenticated against the derived key version,
// which makes accidental key/version mismatches fail closed.
type AESGCM struct {
	aead       cipher.AEAD
	keyVersion string
	random     io.Reader
}

func NewAESGCM(key []byte) (*AESGCM, error) {
	if len(key) != 32 {
		return nil, errors.New("token encryption key must be exactly 32 bytes")
	}
	block, err := aes.NewCipher(append([]byte(nil), key...))
	if err != nil {
		return nil, fmt.Errorf("create token cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("create token AEAD: %w", err)
	}
	digest := sha256.Sum256(key)
	return &AESGCM{
		aead:       aead,
		keyVersion: "aes256gcm-" + hex.EncodeToString(digest[:8]),
		random:     rand.Reader,
	}, nil
}

func (c *AESGCM) Encrypt(ctx context.Context, plaintext string) ([]byte, string, error) {
	if err := ctx.Err(); err != nil {
		return nil, "", err
	}
	if c == nil || c.aead == nil {
		return nil, "", errors.New("token cipher is not configured")
	}
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := io.ReadFull(c.random, nonce); err != nil {
		return nil, "", fmt.Errorf("generate token nonce: %w", err)
	}
	ciphertext := make([]byte, 0, len(nonce)+len(plaintext)+c.aead.Overhead())
	ciphertext = append(ciphertext, nonce...)
	ciphertext = c.aead.Seal(ciphertext, nonce, []byte(plaintext), []byte(c.keyVersion))
	return ciphertext, c.keyVersion, nil
}

func (c *AESGCM) Decrypt(ctx context.Context, ciphertext []byte, keyVersion string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if c == nil || c.aead == nil {
		return "", errors.New("token cipher is not configured")
	}
	if keyVersion != c.keyVersion {
		return "", errors.New("token encryption key version is unavailable")
	}
	nonceSize := c.aead.NonceSize()
	if len(ciphertext) < nonceSize+c.aead.Overhead() {
		return "", errors.New("token ciphertext is invalid")
	}
	nonce := ciphertext[:nonceSize]
	plaintext, err := c.aead.Open(nil, nonce, ciphertext[nonceSize:], []byte(keyVersion))
	if err != nil {
		return "", errors.New("token ciphertext authentication failed")
	}
	return string(plaintext), nil
}

func (c *AESGCM) KeyVersion() string {
	if c == nil {
		return ""
	}
	return c.keyVersion
}
