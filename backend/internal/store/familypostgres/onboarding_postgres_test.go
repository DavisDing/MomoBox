package familypostgres

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/momobox/backend/internal/auth"
	"github.com/momobox/backend/internal/family"
	"github.com/momobox/backend/internal/store/authpostgres"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

type onboardingClock struct{}

func (onboardingClock) Now() time.Time { return time.Now().UTC() }

func TestPostgresFirstHouseholdAndInvitedRegistration(t *testing.T) {
	dsn := strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL"))
	if dsn == "" {
		t.Skip("MOMO_TEST_DATABASE_URL unset")
	}
	var entropy [10]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	schema := "momobox_onboarding_" + hex.EncodeToString(entropy[:])
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid test DSN")
	}
	if config.RuntimeParams == nil {
		config.RuntimeParams = map[string]string{}
	}
	config.RuntimeParams["search_path"] = schema
	db := stdlib.OpenDB(*config)
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	if _, err = db.ExecContext(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := db.ExecContext(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error(err)
		}
	}()
	raw, err := os.ReadFile("../../../migrations/0001_initial_schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	migration := strings.ReplaceAll(string(raw), "SET LOCAL search_path = public;", "SET LOCAL search_path = "+schema+";")
	migration = strings.ReplaceAll(migration, "CREATE EXTENSION IF NOT EXISTS pgcrypto;", "")
	if _, err = db.ExecContext(ctx, migration); err != nil {
		t.Fatal(err)
	}
	if _, err = db.ExecContext(ctx, "ALTER TABLE families ADD COLUMN time_zone TEXT NOT NULL DEFAULT 'Asia/Shanghai'"); err != nil {
		t.Fatal(err)
	}
	users := authpostgres.NewUserRepository(db)
	const owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	const second = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	first := auth.StoredUser{User: auth.User{ID: owner, Email: "owner@example.test", Nickname: "owner"}, PasswordHash: "fixture"}
	other := auth.StoredUser{User: auth.User{ID: second, Email: "second@example.test", Nickname: "second"}, PasswordHash: "fixture"}
	if err = users.CreateFirst(ctx, first); err != nil {
		t.Fatal(err)
	}
	if err = users.CreateFirst(ctx, other); err == nil {
		t.Fatal("second uninvited registration accepted")
	}
	repository := NewRepository(db)
	var wg sync.WaitGroup
	results := make(chan family.FamilyResponse, 2)
	failures := make(chan error, 2)
	for _, id := range []string{"cccccccc-cccc-4ccc-8ccc-cccccccccccc", "dddddddd-dddd-4ddd-8ddd-dddddddddddd"} {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			now := time.Now().UTC()
			result, err := repository.InitializeFirst(ctx,
				family.Family{ID: id, Name: "Home", TimeZone: "Asia/Shanghai", CreatedAt: now}, family.Membership{FamilyID: id, UserID: owner, Role: family.RoleOwner, JoinedAt: now})
			if err != nil {
				failures <- err
			} else {
				results <- result
			}
		}(id)
	}
	wg.Wait()
	close(results)
	close(failures)
	for err := range failures {
		t.Fatal(err)
	}
	familyID := ""
	for result := range results {
		if familyID != "" && familyID != result.Family.ID {
			t.Fatal("concurrent setup created two families")
		}
		familyID = result.Family.ID
	}
	if familyID == "" {
		t.Fatal("no family initialized")
	}
	if err = users.Create(ctx, other); err != nil {
		t.Fatal(err)
	}
	if _, err = repository.InitializeFirst(ctx, family.Family{ID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", Name: "Second", TimeZone: "Asia/Shanghai", CreatedAt: time.Now()}, family.Membership{UserID: second, Role: family.RoleOwner}); err == nil {
		t.Fatal("existing household joined without invite")
	}
	pepper := []byte("test-refresh-pepper-long-enough-only-for-fixtures")
	invitePepper := sha256.Sum256(append([]byte("momobox/family-invite/v1\x00"), pepper...))
	code := "fixture-invite-code"
	hash := family.InviteCodeHasher{Pepper: invitePepper[:]}.Hash(code)
	if err = repository.Create(ctx, family.Invite{ID: "ffffffff-ffff-4fff-8fff-ffffffffffff", FamilyID: familyID, CodeHash: hash, ExpiresAt: time.Now().Add(time.Hour), MaxUses: 2, CreatedBy: owner, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	repos := authpostgres.NewRepositories(db)
	service, err := auth.NewService(repos.Users, repos.RefreshTokens, repository, repos.Devices, auth.BcryptPasswordHasher{},
		auth.HMACJWTIssuer{Secret: []byte("test-jwt-secret-32-byte-fixture-only"), AccessTTL: time.Minute}, auth.SecureRandomTokenSource{}, auth.SecureIDGenerator{}, onboardingClock{},
		auth.ServiceConfig{RegistrationMode: auth.RegistrationFirstSetup, AccessTokenTTL: time.Minute, RefreshTokenTTL: time.Hour, RefreshPepper: pepper})
	if err != nil {
		t.Fatal(err)
	}
	request := auth.RegisterRequest{Email: "invited@example.test", Nickname: "member", Password: "safe-fixture-password", InviteCode: code}
	response, err := service.Register(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	current, member, err := repository.FindCurrentForUser(ctx, response.User.ID)
	if err != nil || current.ID != familyID || member.Role != family.RoleMember {
		t.Fatalf("incorrect invited membership: %v", err)
	}
	if _, err = service.Register(ctx, request); err == nil {
		t.Fatal("duplicate email accepted")
	}
	var used int
	if err = db.QueryRowContext(ctx, "SELECT used_count FROM family_invites").Scan(&used); err != nil || used != 1 {
		t.Fatalf("failed registration consumed invite: %d %v", used, err)
	}
	request.Email = "invalid@example.test"
	request.InviteCode = "unknown-invite"
	if _, err = service.Register(ctx, request); err == nil {
		t.Fatal("unknown invite accepted")
	}
	var count int
	if err = db.QueryRowContext(ctx, "SELECT count(*) FROM users WHERE email='invalid@example.test'").Scan(&count); err != nil || count != 0 {
		t.Fatal("failed invitation left an orphan user")
	}
}
