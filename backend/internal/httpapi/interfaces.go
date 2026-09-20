package httpapi

import (
	"context"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/family"
	homeassistant "github.com/momobox/backend/internal/homeassistant"
	syncservice "github.com/momobox/backend/internal/sync"
	"github.com/momobox/backend/internal/syncdevice"
)

// ClaimsVerifier is the HTTP boundary for bearer-token verification. Keeping
// verification injected prevents handlers from knowing the signing algorithm,
// secret storage, or token implementation.
type ClaimsVerifier interface {
	Verify(token string, now time.Time) (auth.AccessTokenClaims, error)
}

// Dependencies contains application services. Local interfaces make the HTTP
// adapter easy to test and let concrete domain services satisfy it directly.
type Dependencies struct {
	Auth          AuthService
	Family        FamilyService
	Devices       DeviceService
	Sync          SyncService
	HomeAssistant HomeAssistantService
	Verifier      ClaimsVerifier
	Config        Config
}

type AuthService interface {
	Register(context.Context, auth.RegisterRequest) (auth.AuthResponse, error)
	Login(context.Context, auth.LoginRequest) (auth.AuthResponse, error)
	Refresh(context.Context, auth.RefreshRequest) (auth.AuthResponse, error)
	Logout(context.Context, auth.RefreshRequest) error
	CurrentUser(context.Context, string) (auth.MeResponse, error)
}

type FamilyService interface {
	CreateFamily(context.Context, string, family.CreateFamilyRequest) (family.FamilyResponse, error)
	CurrentFamily(context.Context, string) (family.FamilyResponse, error)
	CreateInvite(context.Context, string, string, family.CreateInviteRequest) (family.InviteResponse, error)
	Join(context.Context, string, family.JoinFamilyRequest) (family.FamilyResponse, error)
	ListMembers(context.Context, string, string) (family.MembersResponse, error)
}

type DeviceService interface {
	Register(context.Context, syncdevice.Actor, syncdevice.RegisterDeviceRequest) (syncdevice.SyncDeviceDTO, error)
	ListResponse(context.Context, syncdevice.Actor) (syncdevice.DeviceListResponse, error)
	Revoke(context.Context, syncdevice.Actor, string) error
}

type SyncService interface {
	Bootstrap(context.Context, syncservice.BootstrapRequest) (syncservice.BootstrapResponse, error)
	ConfirmBootstrap(context.Context, syncservice.BootstrapConfirmRequest) (syncservice.BootstrapConfirmResponse, error)
	Pull(context.Context, syncservice.PullRequest) (syncservice.PullResponse, error)
	Push(context.Context, syncservice.PushRequest) (syncservice.PushResponse, error)
}

type HomeAssistantService interface {
	CreateIntegration(context.Context, homeassistant.Actor, homeassistant.AddIntegrationRequest) (homeassistant.IntegrationDTO, error)
	ListIntegrations(context.Context, homeassistant.Actor) ([]homeassistant.IntegrationDTO, error)
	UpdateIntegration(context.Context, homeassistant.Actor, string, homeassistant.UpdateIntegrationRequest) (homeassistant.IntegrationDTO, error)
	DeleteIntegration(context.Context, homeassistant.Actor, string) error
	TestIntegration(context.Context, homeassistant.Actor, string) (homeassistant.ConnectionTestDTO, error)
	Discover(context.Context, homeassistant.Actor, string) (homeassistant.DiscoveryDTO, error)
	ListEntities(context.Context, homeassistant.Actor, string, bool) ([]homeassistant.EntityDTO, error)
	GetState(context.Context, homeassistant.Actor, string, string) (homeassistant.StateDTO, error)
	ExecuteCommand(context.Context, homeassistant.Actor, string, string, homeassistant.CommandRequest) (homeassistant.CommandDTO, error)
	ListPermissions(context.Context, homeassistant.Actor) ([]homeassistant.PermissionDTO, error)
	UpdatePermission(context.Context, homeassistant.Actor, homeassistant.PermissionRequest) (homeassistant.PermissionDTO, error)
}

// Config contains adapter-only limits and clock behavior. It intentionally does
// not duplicate platform configuration.
type Config struct {
	MaxRequestBodyBytes int64
	Now                 func() time.Time
}

const defaultMaxRequestBodyBytes int64 = 1 << 20
