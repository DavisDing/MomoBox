package auth_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/momobox/backend/internal/auth"
)

func TestRefreshBindsRegisteredDeviceAndPreservesBindingOnRotation(t *testing.T) {
	refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
	fixture := newAuthFixture(t, existingUsers(), refresh, auth.RegistrationOpen)
	fixture.memberships.current = auth.FamilyMembership{FamilyID: "family-1", Role: "owner"}
	fixture.memberships.hasCurrent = true
	login, err := fixture.service.Login(context.Background(), auth.LoginRequest{Email: "u@example.com", Password: "correct horse battery"})
	if err != nil {
		t.Fatal(err)
	}
	if fixture.issuer.issued[0].DeviceID != "" {
		t.Fatal("plain login must not infer a device")
	}
	fixture.devices.listed = []auth.SyncDevice{{ID: "phone"}}
	bound, err := fixture.service.Refresh(context.Background(), auth.RefreshRequest{RefreshToken: login.RefreshToken, DeviceID: "phone"})
	if err != nil {
		t.Fatal(err)
	}
	claims := fixture.issuer.issued[len(fixture.issuer.issued)-1]
	if claims.UserID != "user-1" || claims.FamilyID != "family-1" || claims.DeviceID != "phone" {
		t.Fatalf("incorrect device scope: %+v", claims)
	}
	rotated, err := fixture.service.Refresh(context.Background(), auth.RefreshRequest{RefreshToken: bound.RefreshToken})
	if err != nil {
		t.Fatal(err)
	}
	if rotated.RefreshToken == bound.RefreshToken || fixture.issuer.issued[len(fixture.issuer.issued)-1].DeviceID != "phone" {
		t.Fatal("ordinary refresh lost the binding")
	}
	for _, record := range refresh.records {
		if record.RevokedAt == nil && (record.DeviceID != "phone" || record.FamilyID != "family-1") {
			t.Fatalf("incorrect refresh scope: %+v", record)
		}
	}
}

func TestRefreshDeviceBindingFailsClosedWithoutRotating(t *testing.T) {
	for _, scenario := range []string{"unknown", "other-user", "other-family", "revoked", "no-family", "repository-error"} {
		t.Run(scenario, func(t *testing.T) {
			refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
			fixture := newAuthFixture(t, existingUsers(), refresh, auth.RegistrationOpen)
			fixture.memberships.current = auth.FamilyMembership{FamilyID: "family-1", Role: "owner"}
			fixture.memberships.hasCurrent = scenario != "no-family"
			login, err := fixture.service.Login(context.Background(), auth.LoginRequest{Email: "u@example.com", Password: "correct horse battery"})
			if err != nil {
				t.Fatal(err)
			}
			// DeviceReader filters owner/family/deletion in SQL; these foreign
			// devices therefore never appear in the returned list.
			fixture.devices.listed = []auth.SyncDevice{{ID: "different-phone"}}
			if scenario == "revoked" {
				now := time.Now()
				fixture.devices.listed = []auth.SyncDevice{{ID: "phone", RevokedAt: &now}}
			}
			if scenario == "repository-error" {
				fixture.devices.listErr = errors.New("offline")
			}
			_, err = fixture.service.Refresh(context.Background(), auth.RefreshRequest{RefreshToken: login.RefreshToken, DeviceID: "phone"})
			if err == nil {
				t.Fatal("unavailable device was accepted")
			}
			if scenario != "repository-error" {
				assertServiceCode(t, err, auth.CodeInvalidToken)
			}
			if refresh.rotated || len(refresh.records) != 1 || len(fixture.issuer.issued) != 1 {
				t.Fatal("failed binding issued or rotated credentials")
			}
		})
	}
}
