package platform

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
)

const PasswordHashCost = 12

func HashPassword(password string) (string, error) {
	if err := ValidatePassword(password); err != nil {
		return "", err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), PasswordHashCost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}
	return string(hash), nil
}

func ComparePassword(hash, password string) error {
	if hash == "" {
		return bcrypt.ErrMismatchedHashAndPassword
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
}

func ValidatePassword(password string) error {
	length := utf8.RuneCountInString(password)
	if length < 12 || length > 128 {
		return errors.New("password must contain 12 to 128 characters")
	}
	return nil
}

type AccessTokenClaims struct {
	UserID    string `json:"user"`
	FamilyID  string `json:"family,omitempty"`
	Role      string `json:"role,omitempty"`
	DeviceID  string `json:"device,omitempty"`
	IssuedAt  int64  `json:"iat"`
	ExpiresAt int64  `json:"exp"`
}

func SignAccessToken(claims AccessTokenClaims, secret string, now time.Time) (string, error) {
	if len(secret) < 32 {
		return "", errors.New("JWT secret must be at least 32 bytes")
	}
	if claims.UserID == "" {
		return "", errors.New("access token user is required")
	}
	if claims.IssuedAt == 0 {
		claims.IssuedAt = now.Unix()
	}
	if claims.ExpiresAt <= claims.IssuedAt {
		return "", errors.New("access token expiry must be after issue time")
	}
	return signJWT(claims, secret)
}

func ParseAccessToken(token, secret string, now time.Time) (AccessTokenClaims, error) {
	var claims AccessTokenClaims
	if err := parseJWT(token, secret, &claims); err != nil {
		return AccessTokenClaims{}, err
	}
	if claims.UserID == "" || claims.ExpiresAt <= now.Unix() {
		return AccessTokenClaims{}, errors.New("access token is expired or invalid")
	}
	return claims, nil
}

func NewRefreshToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", fmt.Errorf("generate refresh token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

func HashRefreshToken(token, pepper string) string {
	mac := hmac.New(sha256.New, []byte(pepper))
	_, _ = mac.Write([]byte(token))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func signJWT(claims any, secret string) (string, error) {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("encode token claims: %w", err)
	}
	encodedPayload := base64.RawURLEncoding.EncodeToString(payload)
	unsigned := header + "." + encodedPayload
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(unsigned))
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func parseJWT(token, secret string, destination any) error {
	if len(secret) < 32 {
		return errors.New("JWT secret must be at least 32 bytes")
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return errors.New("malformed access token")
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return errors.New("malformed access token header")
	}
	var header struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil || header.Alg != "HS256" || header.Typ != "JWT" {
		return errors.New("invalid access token header")
	}
	unsigned := parts[0] + "." + parts[1]
	provided, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return errors.New("malformed access token signature")
	}
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(unsigned))
	if !hmac.Equal(provided, mac.Sum(nil)) {
		return errors.New("invalid access token signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return errors.New("malformed access token payload")
	}
	if err := json.Unmarshal(payload, destination); err != nil {
		return errors.New("invalid access token claims")
	}
	return nil
}
