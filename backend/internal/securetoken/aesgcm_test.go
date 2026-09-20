package securetoken

import (
	"context"
	"strings"
	"testing"
)

func TestAESGCMRoundTripAndTamperDetection(t *testing.T) {
	cipher, err := NewAESGCM([]byte(strings.Repeat("k", 32)))
	if err != nil {
		t.Fatal(err)
	}
	ciphertext, version, err := cipher.Encrypt(context.Background(), "secret-token")
	if err != nil {
		t.Fatal(err)
	}
	if string(ciphertext) == "secret-token" || version == "" {
		t.Fatal("ciphertext or key version was not produced")
	}
	plaintext, err := cipher.Decrypt(context.Background(), ciphertext, version)
	if err != nil || plaintext != "secret-token" {
		t.Fatalf("round trip failed: plaintext=%q err=%v", plaintext, err)
	}

	ciphertext[len(ciphertext)-1] ^= 1
	if _, err := cipher.Decrypt(context.Background(), ciphertext, version); err == nil {
		t.Fatal("tampered ciphertext was accepted")
	}
}

func TestAESGCMRejectsWrongKeySizeAndVersion(t *testing.T) {
	if _, err := NewAESGCM([]byte("short")); err == nil {
		t.Fatal("short key was accepted")
	}
	cipher, err := NewAESGCM([]byte(strings.Repeat("k", 32)))
	if err != nil {
		t.Fatal(err)
	}
	ciphertext, _, err := cipher.Encrypt(context.Background(), "secret-token")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := cipher.Decrypt(context.Background(), ciphertext, "unknown"); err == nil {
		t.Fatal("unknown key version was accepted")
	}
}
