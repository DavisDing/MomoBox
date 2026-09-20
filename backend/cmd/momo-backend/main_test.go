package main

import (
	"context"
	"errors"
	"testing"

	"github.com/momobox/backend/internal/family"
	"github.com/momobox/backend/internal/homeassistant"
)

type recordingHomeAssistantApplication struct {
	homeAssistantApplication
	actorID       string
	integrationID string
	entityID      string
	err           error
}

func (f *recordingHomeAssistantApplication) GetState(ctx context.Context, _ homeassistant.Actor, integrationID, entityID string) (homeassistant.StateDTO, error) {
	f.actorID, f.err = homeAssistantActorResolver(ctx)
	f.integrationID = integrationID
	f.entityID = entityID
	return homeassistant.StateDTO{}, f.err
}

func (f *recordingHomeAssistantApplication) CreateIntegration(ctx context.Context, _ homeassistant.Actor, _ homeassistant.AddIntegrationRequest) (homeassistant.IntegrationDTO, error) {
	f.actorID, f.err = homeAssistantActorResolver(ctx)
	return homeassistant.IntegrationDTO{}, f.err
}

type membershipFinderStub struct {
	membership family.Membership
	err        error
}

func (s membershipFinderStub) Find(context.Context, string, string) (family.Membership, error) {
	return s.membership, s.err
}

func TestAttributedHomeAssistantServiceInjectsTrustedActor(t *testing.T) {
	application := &recordingHomeAssistantApplication{}
	service := &attributedHomeAssistantService{service: application}
	actor := homeassistant.Actor{UserID: "user-1", FamilyID: "family-1", Role: homeassistant.RoleAdmin}

	if _, err := service.CreateIntegration(context.Background(), actor, homeassistant.AddIntegrationRequest{}); err != nil {
		t.Fatalf("CreateIntegration() error = %v", err)
	}
	if application.actorID != actor.UserID {
		t.Fatalf("trusted actor = %q, want %q", application.actorID, actor.UserID)
	}
}

func TestAttributedHomeAssistantServiceForwardsIntegrationScopedEntityKey(t *testing.T) {
	application := &recordingHomeAssistantApplication{}
	service := &attributedHomeAssistantService{service: application}
	actor := homeassistant.Actor{UserID: "user-1", FamilyID: "family-1", Role: homeassistant.RoleAdmin}

	if _, err := service.GetState(context.Background(), actor, "integration-2", "light.kitchen"); err != nil {
		t.Fatalf("GetState() error = %v", err)
	}
	if application.actorID != actor.UserID || application.integrationID != "integration-2" || application.entityID != "light.kitchen" {
		t.Fatalf("forwarded actor/key = %q/%q/%q", application.actorID, application.integrationID, application.entityID)
	}
}

func TestHomeAssistantActorResolverFailsClosed(t *testing.T) {
	if _, err := homeAssistantActorResolver(context.Background()); err == nil {
		t.Fatal("homeAssistantActorResolver() succeeded without trusted actor")
	}
}

func TestHomeAssistantRoleResolverMapsMembershipRoles(t *testing.T) {
	tests := []struct {
		name string
		role family.Role
		want homeassistant.Role
	}{
		{name: "owner", role: family.RoleOwner, want: homeassistant.RoleOwner},
		{name: "admin", role: family.RoleAdmin, want: homeassistant.RoleAdmin},
		{name: "member", role: family.RoleMember, want: homeassistant.RoleMember},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			resolver := homeAssistantRoleResolver{memberships: membershipFinderStub{membership: family.Membership{
				FamilyID: "family-1",
				UserID:   "user-1",
				Role:     test.role,
			}}}
			got, err := resolver.ResolveSyncRole(context.Background(), "family-1", "user-1")
			if err != nil {
				t.Fatalf("ResolveSyncRole() error = %v", err)
			}
			if got != test.want {
				t.Fatalf("ResolveSyncRole() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestHomeAssistantRoleResolverRejectsUntrustedOrMissingMembership(t *testing.T) {
	tests := []struct {
		name   string
		finder familyMembershipFinder
	}{
		{name: "not configured", finder: nil},
		{name: "repository error", finder: membershipFinderStub{err: errors.New("lookup failed")}},
		{name: "family mismatch", finder: membershipFinderStub{membership: family.Membership{FamilyID: "other-family", UserID: "user-1", Role: family.RoleMember}}},
		{name: "user mismatch", finder: membershipFinderStub{membership: family.Membership{FamilyID: "family-1", UserID: "other-user", Role: family.RoleMember}}},
		{name: "unsupported role", finder: membershipFinderStub{membership: family.Membership{FamilyID: "family-1", UserID: "user-1", Role: family.Role("guest")}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			resolver := homeAssistantRoleResolver{memberships: test.finder}
			if _, err := resolver.ResolveSyncRole(context.Background(), "family-1", "user-1"); err == nil {
				t.Fatal("ResolveSyncRole() succeeded, want error")
			}
		})
	}
}

func TestServeRequiresDatabaseURLBeforeOtherConfiguration(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	if err := serve(context.Background()); err == nil || err.Error() != "serve requires DATABASE_URL" {
		t.Fatalf("serve() error = %v, want DATABASE_URL requirement", err)
	}
}
