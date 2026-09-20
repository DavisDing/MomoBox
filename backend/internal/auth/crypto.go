package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// SecureRandomTokenSource generates opaque, URL-safe tokens. It is suitable
// for refresh and invite-token implementations; repositories should store
// only a hash of the returned value.
type SecureRandomTokenSource struct {
	Bytes int
}

func (s SecureRandomTokenSource) RandomToken() (string, error) {
	n := s.Bytes
	if n == 0 {
		n = 32
	}
	if n < 32 {
		return "", errors.New("random token size must be at least 32 bytes")
	}
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

type SecureIDGenerator struct{}

func (SecureIDGenerator) NewID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	// UUID v4 without requiring a UUID dependency.
	buf[6] = (buf[6] & 0x0f) | 0x40
	buf[8] = (buf[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", buf[0:4], buf[4:6], buf[6:8], buf[8:10], buf[10:16]), nil
}

// HMACRefreshTokenHasher deliberately produces a one-way, peppered digest.
// The pepper must come from deployment configuration and never from source.
type HMACRefreshTokenHasher struct{ Pepper []byte }

func (h HMACRefreshTokenHasher) Hash(token string) string {
	mac := hmac.New(sha256.New, h.Pepper)
	_, _ = mac.Write([]byte(token))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// HMACJWTIssuer implements the JWT HS256 wire format with only the claims
// needed by this domain. It is intentionally small and dependency-free; an
// HTTP adapter can replace it with a standards library implementation.
type HMACJWTIssuer struct {
	Secret    []byte
	AccessTTL time.Duration
}

type jwtHeader struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
}
type jwtClaims struct {
	Subject  string `json:"sub"`
	FamilyID string `json:"family_id,omitempty"`
	Role     string `json:"role,omitempty"`
	DeviceID string `json:"device_id,omitempty"`
	IssuedAt int64  `json:"iat"`
	Expires  int64  `json:"exp"`
}

func (i HMACJWTIssuer) Issue(claims AccessTokenClaims) (string, error) {
	if len(i.Secret) == 0 || claims.UserID == "" || claims.ExpiresAt.IsZero() {
		return "", errors.New("invalid access token issuer configuration or claims")
	}
	header, _ := json.Marshal(jwtHeader{Alg: "HS256", Typ: "JWT"})
	payload, err := json.Marshal(jwtClaims{Subject: claims.UserID, FamilyID: claims.FamilyID, Role: claims.Role, DeviceID: claims.DeviceID, IssuedAt: claims.IssuedAt.Unix(), Expires: claims.ExpiresAt.Unix()})
	if err != nil {
		return "", err
	}
	encodedHeader := base64.RawURLEncoding.EncodeToString(header)
	encodedPayload := base64.RawURLEncoding.EncodeToString(payload)
	input := encodedHeader + "." + encodedPayload
	mac := hmac.New(sha256.New, i.Secret)
	_, _ = mac.Write([]byte(input))
	return input + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func (i HMACJWTIssuer) Verify(token string, now time.Time) (AccessTokenClaims, error) {
	var empty AccessTokenClaims
	if len(i.Secret) == 0 {
		return empty, errors.New("missing jwt secret")
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return empty, errors.New("malformed jwt")
	}
	mac := hmac.New(sha256.New, i.Secret)
	_, _ = mac.Write([]byte(parts[0] + "." + parts[1]))
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || subtle.ConstantTimeCompare(sig, mac.Sum(nil)) != 1 {
		return empty, errors.New("invalid jwt signature")
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return empty, err
	}
	var header jwtHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil || header.Alg != "HS256" || header.Typ != "JWT" {
		return empty, errors.New("invalid jwt header")
	}
	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return empty, err
	}
	var payload jwtClaims
	if err := json.Unmarshal(payloadBytes, &payload); err != nil || payload.Subject == "" {
		return empty, errors.New("invalid jwt claims")
	}
	if payload.Expires <= now.Unix() {
		return empty, errors.New("jwt expired")
	}
	return AccessTokenClaims{UserID: payload.Subject, FamilyID: payload.FamilyID, Role: payload.Role, DeviceID: payload.DeviceID, IssuedAt: time.Unix(payload.IssuedAt, 0).UTC(), ExpiresAt: time.Unix(payload.Expires, 0).UTC()}, nil
}
