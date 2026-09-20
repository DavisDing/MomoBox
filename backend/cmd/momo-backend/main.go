package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/family"
	"github.com/momobox/backend/internal/homeassistant"
	"github.com/momobox/backend/internal/httpapi"
	"github.com/momobox/backend/internal/platform"
	"github.com/momobox/backend/internal/securetoken"
	"github.com/momobox/backend/internal/store/authpostgres"
	"github.com/momobox/backend/internal/store/familypostgres"
	"github.com/momobox/backend/internal/store/hahttp"
	"github.com/momobox/backend/internal/store/hapostgres"
	"github.com/momobox/backend/internal/store/syncpostgres"
	syncservice "github.com/momobox/backend/internal/sync"
	"github.com/momobox/backend/internal/syncdevice"
)

const databaseStartupTimeout = 10 * time.Second

type systemClock struct{}

func (systemClock) Now() time.Time { return time.Now().UTC() }

type homeAssistantActorContextKey struct{}

func contextWithHomeAssistantActor(ctx context.Context, actor homeassistant.Actor) context.Context {
	return context.WithValue(ctx, homeAssistantActorContextKey{}, strings.TrimSpace(actor.UserID))
}

func homeAssistantActorResolver(ctx context.Context) (string, error) {
	actorID, ok := ctx.Value(homeAssistantActorContextKey{}).(string)
	if !ok || strings.TrimSpace(actorID) == "" {
		return "", errors.New("trusted Home Assistant actor is missing from context")
	}
	return actorID, nil
}

type homeAssistantApplication interface {
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

// attributedHomeAssistantService is the only Home Assistant service exposed by
// the production composition root. It derives repository attribution from the
// already-authenticated Actor and stores it under a private context key that no
// HTTP payload or external package can forge.
type attributedHomeAssistantService struct {
	service homeAssistantApplication
}

func (s *attributedHomeAssistantService) CreateIntegration(ctx context.Context, actor homeassistant.Actor, request homeassistant.AddIntegrationRequest) (homeassistant.IntegrationDTO, error) {
	return s.service.CreateIntegration(contextWithHomeAssistantActor(ctx, actor), actor, request)
}

func (s *attributedHomeAssistantService) ListIntegrations(ctx context.Context, actor homeassistant.Actor) ([]homeassistant.IntegrationDTO, error) {
	return s.service.ListIntegrations(contextWithHomeAssistantActor(ctx, actor), actor)
}

func (s *attributedHomeAssistantService) UpdateIntegration(ctx context.Context, actor homeassistant.Actor, integrationID string, request homeassistant.UpdateIntegrationRequest) (homeassistant.IntegrationDTO, error) {
	return s.service.UpdateIntegration(contextWithHomeAssistantActor(ctx, actor), actor, integrationID, request)
}

func (s *attributedHomeAssistantService) DeleteIntegration(ctx context.Context, actor homeassistant.Actor, integrationID string) error {
	return s.service.DeleteIntegration(contextWithHomeAssistantActor(ctx, actor), actor, integrationID)
}

func (s *attributedHomeAssistantService) TestIntegration(ctx context.Context, actor homeassistant.Actor, integrationID string) (homeassistant.ConnectionTestDTO, error) {
	return s.service.TestIntegration(contextWithHomeAssistantActor(ctx, actor), actor, integrationID)
}

func (s *attributedHomeAssistantService) Discover(ctx context.Context, actor homeassistant.Actor, integrationID string) (homeassistant.DiscoveryDTO, error) {
	return s.service.Discover(contextWithHomeAssistantActor(ctx, actor), actor, integrationID)
}

func (s *attributedHomeAssistantService) ListEntities(ctx context.Context, actor homeassistant.Actor, integrationID string, visibleOnly bool) ([]homeassistant.EntityDTO, error) {
	return s.service.ListEntities(contextWithHomeAssistantActor(ctx, actor), actor, integrationID, visibleOnly)
}

func (s *attributedHomeAssistantService) GetState(ctx context.Context, actor homeassistant.Actor, integrationID, entityID string) (homeassistant.StateDTO, error) {
	return s.service.GetState(contextWithHomeAssistantActor(ctx, actor), actor, integrationID, entityID)
}

func (s *attributedHomeAssistantService) ExecuteCommand(ctx context.Context, actor homeassistant.Actor, integrationID, entityID string, request homeassistant.CommandRequest) (homeassistant.CommandDTO, error) {
	return s.service.ExecuteCommand(contextWithHomeAssistantActor(ctx, actor), actor, integrationID, entityID, request)
}

func (s *attributedHomeAssistantService) ListPermissions(ctx context.Context, actor homeassistant.Actor) ([]homeassistant.PermissionDTO, error) {
	return s.service.ListPermissions(contextWithHomeAssistantActor(ctx, actor), actor)
}

func (s *attributedHomeAssistantService) UpdatePermission(ctx context.Context, actor homeassistant.Actor, request homeassistant.PermissionRequest) (homeassistant.PermissionDTO, error) {
	return s.service.UpdatePermission(contextWithHomeAssistantActor(ctx, actor), actor, request)
}

type familyMembershipFinder interface {
	Find(context.Context, string, string) (family.Membership, error)
}

type homeAssistantRoleResolver struct {
	memberships familyMembershipFinder
}

func (r homeAssistantRoleResolver) ResolveSyncRole(ctx context.Context, familyID, userID string) (homeassistant.Role, error) {
	if r.memberships == nil {
		return "", errors.New("Home Assistant sync role resolver is not configured")
	}
	membership, err := r.memberships.Find(ctx, familyID, userID)
	if err != nil {
		return "", fmt.Errorf("resolve Home Assistant sync membership: %w", err)
	}
	if membership.FamilyID != familyID || membership.UserID != userID {
		return "", errors.New("resolved Home Assistant sync membership is outside actor scope")
	}
	switch membership.Role {
	case family.RoleOwner:
		return homeassistant.RoleOwner, nil
	case family.RoleAdmin:
		return homeassistant.RoleAdmin, nil
	case family.RoleMember:
		return homeassistant.RoleMember, nil
	default:
		return "", fmt.Errorf("unsupported family role %q", membership.Role)
	}
}

var (
	_ httpapi.HomeAssistantService     = (*attributedHomeAssistantService)(nil)
	_ homeassistant.SyncCommandService = (*attributedHomeAssistantService)(nil)
	_ homeassistant.SyncRoleResolver   = homeAssistantRoleResolver{}
)

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	command := "serve"
	if len(args) > 0 {
		command = args[0]
	}
	switch command {
	case "serve":
		return serve(ctx)
	case "migrate":
		return migrate(ctx)
	case "healthcheck":
		return healthcheck(ctx)
	case "help", "-h", "--help":
		fmt.Println("usage: momo-backend [serve|migrate|healthcheck]")
		return nil
	default:
		return fmt.Errorf("unknown command %q (expected serve, migrate, or healthcheck)", command)
	}
}

func serve(ctx context.Context) error {
	if strings.TrimSpace(os.Getenv("DATABASE_URL")) == "" {
		return errors.New("serve requires DATABASE_URL")
	}
	cfg, err := platform.LoadConfig()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	db, err := platform.OpenPostgresSQL(cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	defer db.Close()

	startupCtx, cancelStartup := context.WithTimeout(ctx, databaseStartupTimeout)
	defer cancelStartup()
	if err := db.PingContext(startupCtx); err != nil {
		return fmt.Errorf("connect database: %w", err)
	}

	authRepositories := authpostgres.NewRepositories(db)
	familyRepositories := familypostgres.NewRepositories(db)
	clock := systemClock{}
	issuer := auth.HMACJWTIssuer{
		Secret:    []byte(cfg.JWTSecret),
		AccessTTL: cfg.AccessTokenTTL,
	}
	authService, err := auth.NewService(
		authRepositories.Users,
		authRepositories.RefreshTokens,
		familyRepositories.Memberships,
		authRepositories.Devices,
		auth.BcryptPasswordHasher{},
		issuer,
		auth.SecureRandomTokenSource{},
		auth.SecureIDGenerator{},
		clock,
		auth.ServiceConfig{
			RegistrationMode: auth.RegistrationMode(cfg.RegistrationMode),
			AccessTokenTTL:   cfg.AccessTokenTTL,
			RefreshTokenTTL:  cfg.RefreshTokenTTL,
			RefreshPepper:    []byte(cfg.RefreshTokenPepper),
		},
	)
	if err != nil {
		return fmt.Errorf("compose auth service: %w", err)
	}

	invitePepper := sha256.Sum256([]byte("momobox/family-invite/v1\x00" + cfg.RefreshTokenPepper))
	familyService, err := family.NewService(
		familyRepositories.Families,
		familyRepositories.Memberships,
		familyRepositories.Invites,
		familyRepositories.Joiner,
		auth.SecureIDGenerator{},
		family.SecureInviteCodeGenerator{},
		clock,
		invitePepper[:],
	)
	if err != nil {
		return fmt.Errorf("compose family service: %w", err)
	}

	deviceService := syncdevice.NewService(authRepositories.SyncDevices, nil)

	tokenCipher, err := securetoken.NewAESGCM([]byte(cfg.HATokenEncryptionKey))
	if err != nil {
		return fmt.Errorf("compose Home Assistant token cipher: %w", err)
	}
	haRepositories := hapostgres.NewRepositories(db, homeAssistantActorResolver)
	haDomainService := homeassistant.NewService(
		haRepositories.Integrations,
		haRepositories.Devices,
		haRepositories.Entities,
		haRepositories.Permissions,
		haRepositories.Audit,
		tokenCipher,
		hahttp.New(nil),
	)
	haService := &attributedHomeAssistantService{service: haDomainService}

	haSyncExecutor := homeassistant.NewSyncExecutor(
		haService,
		homeAssistantRoleResolver{memberships: familyRepositories.Memberships},
	)
	syncRepository := syncpostgres.New(db, syncpostgres.WithHomeAssistantExecutor(haSyncExecutor))
	syncService := syncservice.NewService(syncRepository)

	businessRoutes := httpapi.NewRouter(httpapi.Dependencies{
		Auth:          authService,
		Family:        familyService,
		Devices:       deviceService,
		Sync:          syncService,
		HomeAssistant: haService,
		Verifier:      issuer,
		Config: httpapi.Config{
			MaxRequestBodyBytes: cfg.MaxRequestBodyBytes,
			Now:                 time.Now,
		},
	})
	server := platform.NewHTTPServerWithRoutes(cfg, db, businessRoutes)

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	fmt.Printf("momo-backend %s listening on %s\n", cfg.AppVersion, cfg.HTTPAddr)
	if err := server.HTTPServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve HTTP: %w", err)
	}
	return nil
}

func migrate(ctx context.Context) error {
	cfg, err := platform.LoadConfig()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	directory := os.Getenv("MIGRATIONS_DIR")
	if err := (platform.SQLMigrationRunner{DatabaseURL: cfg.DatabaseURL, Directory: directory}).Run(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

func healthcheck(ctx context.Context) error {
	cfg, err := platform.LoadConfig()
	if err != nil {
		return err
	}
	host, port, err := net.SplitHostPort(cfg.HTTPAddr)
	if err != nil {
		return err
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	url := "http://" + net.JoinHostPort(host, port) + "/api/v1/health"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	client := http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("health endpoint returned %s", resp.Status)
	}
	return nil
}
