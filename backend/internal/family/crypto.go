package family

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
)

// SecureInviteCodeGenerator generates an opaque code. Only its hash should be
// passed to InviteRepository; the raw code is returned once in InviteResponse.
type SecureInviteCodeGenerator struct{ Bytes int }

func (g SecureInviteCodeGenerator) NewCode() (string, error) {
	n := g.Bytes
	if n == 0 {
		n = 24
	}
	if n < 16 {
		return "", errors.New("invite code size must be at least 16 bytes")
	}
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

type InviteCodeHasher struct{ Pepper []byte }

func (h InviteCodeHasher) Hash(code string) string {
	mac := hmac.New(sha256.New, h.Pepper)
	_, _ = mac.Write([]byte(code))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
