package auth_test

import (
	"context"
	"errors"
	"testing"
	"time"

	auth "github.com/momobox/backend/internal/auth"
)

type testClock struct{ now time.Time }

func (c testClock) Now() time.Time { return c.now }

type testIDs struct{ next int }

func (g *testIDs) NewID() (string, error) {
	g.next++
	return "id-" + string(rune('0'+g.next)), nil
}

type testRandom struct{ next int }

func (r *testRandom) RandomToken() (string, error) {
	r.next++
	return "refresh-token-value-abcdefghijklmnopqrstuvwxyz-" + string(rune('0'+r.next)), nil
}

type testHasher struct{}

func (testHasher) Hash(password string) (string, error) { return "hash:" + password, nil }
func (testHasher) Compare(encoded, password string) error {
	if encoded != "hash:"+password {
		return errors.New("mismatch")
	}
	return nil
}

type userRepo struct{ users map[string]auth.StoredUser }

func (r *userRepo) Count(context.Context) (int, error) { return len(r.users), nil }
func (r *userRepo) FindByEmail(_ context.Context, email string) (auth.StoredUser, error) {
	for _, user := range r.users {
		if user.Email == email {
			return user, nil
		}
	}
	return auth.StoredUser{}, errors.New("not found")
}
func (r *userRepo) FindByID(_ context.Context, id string) (auth.StoredUser, error) {
	user, ok := r.users[id]
	if !ok {
		return auth.StoredUser{}, errors.New("not found")
	}
	return user, nil
}
func (r *userRepo) Create(_ context.Context, user auth.StoredUser) error {
	for _, existing := range r.users {
		if existing.Email == user.Email {
			return &auth.ServiceError{Code: auth.CodeEmailAlreadyExists, Message: "exists"}
		}
	}
	r.users[user.ID] = user
	return nil
}

type refreshRepo struct {
	records map[string]auth.RefreshTokenRecord
	rotated bool
}

func (r *refreshRepo) FindByHash(_ context.Context, hash string) (auth.RefreshTokenRecord, error) {
	record, ok := r.records[hash]
	if !ok {
		return auth.RefreshTokenRecord{}, errors.New("not found")
	}
	return record, nil
}
func (r *refreshRepo) Create(_ context.Context, record auth.RefreshTokenRecord) error {
	r.records[record.TokenHash] = record
	return nil
}
func (r *refreshRepo) Rotate(_ context.Context, oldHash string, replacement auth.RefreshTokenRecord, now time.Time) error {
	record, ok := r.records[oldHash]
	if !ok {
		return errors.New("not found")
	}
	record.RevokedAt = &now
	record.ReplacedBy = replacement.ID
	r.records[oldHash] = record
	r.records[replacement.TokenHash] = replacement
	r.rotated = true
	return nil
}
func (r *refreshRepo) Revoke(_ context.Context, hash string, now time.Time) error {
	record, ok := r.records[hash]
	if !ok {
		return errors.New("not found")
	}
	record.RevokedAt = &now
	r.records[hash] = record
	return nil
}

type membershipRepo struct {
	current     auth.FamilyMembership
	hasCurrent  bool
	memberships []auth.FamilyMembership
}

func (r *membershipRepo) ListUserMemberships(context.Context, string) ([]auth.FamilyMembership, error) {
	return r.memberships, nil
}
func (r *membershipRepo) CurrentUserMembership(context.Context, string) (auth.FamilyMembership, bool, error) {
	return r.current, r.hasCurrent, nil
}

type deviceRepo struct {
	upserted []auth.DeviceRecord
}

func (r *deviceRepo) ListUserDevices(context.Context, string) ([]auth.SyncDevice, error) {
	return nil, nil
}
func (r *deviceRepo) UpsertDevice(_ context.Context, record auth.DeviceRecord) error {
	r.upserted = append(r.upserted, record)
	return nil
}

type recordingIssuer struct {
	issued []auth.AccessTokenClaims
}

func (i *recordingIssuer) Issue(claims auth.AccessTokenClaims) (string, error) {
	i.issued = append(i.issued, claims)
	return "access:" + claims.UserID, nil
}
func (i *recordingIssuer) Verify(token string, _ time.Time) (auth.AccessTokenClaims, error) {
	if token != "access:user-1" {
		return auth.AccessTokenClaims{}, errors.New("invalid")
	}
	return auth.AccessTokenClaims{UserID: "user-1"}, nil
}

type authFixture struct {
	service     *auth.Service
	memberships *membershipRepo
	devices     *deviceRepo
	issuer      *recordingIssuer
}

func newAuthFixture(t *testing.T, users *userRepo, refresh *refreshRepo, mode auth.RegistrationMode) authFixture {
	t.Helper()
	memberships := &membershipRepo{}
	devices := &deviceRepo{}
	issuer := &recordingIssuer{}
	service, err := auth.NewService(
		users,
		refresh,
		memberships,
		devices,
		testHasher{},
		issuer,
		&testRandom{},
		&testIDs{},
		testClock{now: time.Date(2026, 9, 20, 10, 30, 0, 0, time.UTC)},
		auth.ServiceConfig{RegistrationMode: mode, RefreshPepper: []byte("pepper")},
	)
	if err != nil {
		t.Fatal(err)
	}
	return authFixture{service: service, memberships: memberships, devices: devices, issuer: issuer}
}

func TestRegisterNormalizesEmailAndStoresOnlyRefreshHash(t *testing.T) {
	users := &userRepo{users: map[string]auth.StoredUser{}}
	refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
	fixture := newAuthFixture(t, users, refresh, auth.RegistrationOpen)

	response, err := fixture.service.Register(context.Background(), auth.RegisterRequest{
		Email: "  User@Example.COM ", Password: "correct horse battery", Nickname: " Momo ",
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.User.Email != "user@example.com" || response.User.Nickname != "Momo" {
		t.Fatalf("unexpected user: %+v", response.User)
	}
	if len(refresh.records) != 1 {
		t.Fatalf("refresh records = %d, want 1", len(refresh.records))
	}
	for hash, record := range refresh.records {
		if hash == response.RefreshToken || record.TokenHash == response.RefreshToken {
			t.Fatal("raw refresh token was stored")
		}
		if record.FamilyID != "" || record.DeviceID != "" {
			t.Fatalf("new user token unexpectedly scoped: %+v", record)
		}
	}
	if len(fixture.issuer.issued) != 1 {
		t.Fatalf("issued claims = %d, want 1", len(fixture.issuer.issued))
	}
	claims := fixture.issuer.issued[0]
	if claims.FamilyID != "" || claims.Role != "" || claims.DeviceID != "" {
		t.Fatalf("new user claims unexpectedly scoped: %+v", claims)
	}
}

func TestRegisterRejectsDeviceUntilUserJoinsFamily(t *testing.T) {
	users := &userRepo{users: map[string]auth.StoredUser{}}
	refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
	fixture := newAuthFixture(t, users, refresh, auth.RegistrationOpen)

	_, err := fixture.service.Register(context.Background(), auth.RegisterRequest{
		Email: "user@example.com", Password: "correct horse battery", Nickname: "Momo",
		Device: &auth.RegisterDeviceRequest{DeviceID: "device-1", DeviceName: "Phone", Platform: "ios"},
	})
	assertServiceCode(t, err, auth.CodeValidation)
	if len(users.users) != 0 || len(refresh.records) != 0 {
		t.Fatal("registration wrote data before rejecting the device")
	}
}

func TestFirstSetupClosesRegistrationAfterFirstUser(t *testing.T) {
	users := &userRepo{users: map[string]auth.StoredUser{}}
	refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
	fixture := newAuthFixture(t, users, refresh, auth.RegistrationFirstSetup)
	request := auth.RegisterRequest{Email: "one@example.com", Password: "correct horse battery", Nickname: "One"}
	if _, err := fixture.service.Register(context.Background(), request); err != nil {
		t.Fatal(err)
	}
	_, err := fixture.service.Register(context.Background(), auth.RegisterRequest{
		Email: "two@example.com", Password: "correct horse battery", Nickname: "Two",
	})
	assertServiceCode(t, err, auth.CodeRegistrationClosed)
}

func TestLoginScopesDeviceAndTokensToCurrentFamily(t *testing.T) {
	users := existingUsers()
	refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
	fixture := newAuthFixture(t, users, refresh, auth.RegistrationOpen)
	fixture.memberships.current = auth.FamilyMembership{FamilyID: "family-1", Role: "admin"}
	fixture.memberships.hasCurrent = true

	_, err := fixture.service.Login(context.Background(), auth.LoginRequest{
		Email: "u@example.com", Password: "correct horse battery",
		Device: &auth.RegisterDeviceRequest{DeviceID: "device-1", DeviceName: " Phone ", Platform: "android", AppVersion: " 1.2.3 "},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(fixture.devices.upserted) != 1 {
		t.Fatalf("upserted devices = %d, want 1", len(fixture.devices.upserted))
	}
	device := fixture.devices.upserted[0]
	if device.UserID != "user-1" || device.FamilyID != "family-1" || device.ID != "device-1" || device.DeviceName != "Phone" || device.AppVersion != "1.2.3" {
		t.Fatalf("unexpected device record: %+v", device)
	}
	claims := fixture.issuer.issued[len(fixture.issuer.issued)-1]
	if claims.UserID != "user-1" || claims.FamilyID != "family-1" || claims.Role != "admin" || claims.DeviceID != "device-1" {
		t.Fatalf("unexpected access claims: %+v", claims)
	}
	for _, record := range refresh.records {
		if record.FamilyID != "family-1" || record.DeviceID != "device-1" {
			t.Fatalf("unexpected refresh scope: %+v", record)
		}
	}
}

func TestLoginRejectsDeviceWhenNoCurrentFamilyExists(t *testing.T) {
	refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
	fixture := newAuthFixture(t, existingUsers(), refresh, auth.RegistrationOpen)

	_, err := fixture.service.Login(context.Background(), auth.LoginRequest{
		Email: "u@example.com", Password: "correct horse battery",
		Device: &auth.RegisterDeviceRequest{DeviceID: "device-1", DeviceName: "Phone", Platform: "ios"},
	})
	assertServiceCode(t, err, auth.CodeValidation)
	if len(fixture.devices.upserted) != 0 || len(refresh.records) != 0 {
		t.Fatal("login persisted a device or token without a family")
	}
}

func TestRefreshReReadsCurrentFamilyAndDropsOldFamilyDevice(t *testing.T) {
	refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
	fixture := newAuthFixture(t, existingUsers(), refresh, auth.RegistrationOpen)
	fixture.memberships.current = auth.FamilyMembership{FamilyID: "family-1", Role: "member"}
	fixture.memberships.hasCurrent = true

	login, err := fixture.service.Login(context.Background(), auth.LoginRequest{
		Email: "u@example.com", Password: "correct horse battery",
		Device: &auth.RegisterDeviceRequest{DeviceID: "device-1", DeviceName: "Phone", Platform: "ios"},
	})
	if err != nil {
		t.Fatal(err)
	}
	fixture.memberships.current = auth.FamilyMembership{FamilyID: "family-2", Role: "admin"}

	rotated, err := fixture.service.Refresh(context.Background(), auth.RefreshRequest{RefreshToken: login.RefreshToken})
	if err != nil {
		t.Fatal(err)
	}
	if rotated.RefreshToken == login.RefreshToken || !refresh.rotated {
		t.Fatal("refresh token was not rotated")
	}
	claims := fixture.issuer.issued[len(fixture.issuer.issued)-1]
	if claims.FamilyID != "family-2" || claims.Role != "admin" || claims.DeviceID != "" {
		t.Fatalf("unexpected refreshed claims: %+v", claims)
	}
	var replacement auth.RefreshTokenRecord
	for _, record := range refresh.records {
		if record.RevokedAt == nil {
			replacement = record
		}
	}
	if replacement.FamilyID != "family-2" || replacement.DeviceID != "" {
		t.Fatalf("unexpected replacement refresh scope: %+v", replacement)
	}
}

func TestRefreshRotatesAndLogoutRevokes(t *testing.T) {
	refresh := &refreshRepo{records: map[string]auth.RefreshTokenRecord{}}
	fixture := newAuthFixture(t, existingUsers(), refresh, auth.RegistrationOpen)

	login, err := fixture.service.Login(context.Background(), auth.LoginRequest{Email: "u@example.com", Password: "correct horse battery"})
	if err != nil {
		t.Fatal(err)
	}
	rotated, err := fixture.service.Refresh(context.Background(), auth.RefreshRequest{RefreshToken: login.RefreshToken})
	if err != nil {
		t.Fatal(err)
	}
	if rotated.RefreshToken == login.RefreshToken || !refresh.rotated {
		t.Fatal("refresh token was not rotated")
	}
	if err := fixture.service.Logout(context.Background(), auth.RefreshRequest{RefreshToken: rotated.RefreshToken}); err != nil {
		t.Fatal(err)
	}
	if _, err := fixture.service.Refresh(context.Background(), auth.RefreshRequest{RefreshToken: rotated.RefreshToken}); err == nil {
		t.Fatal("revoked token refreshed successfully")
	}
}

func existingUsers() *userRepo {
	return &userRepo{users: map[string]auth.StoredUser{
		"user-1": {
			User:         auth.User{ID: "user-1", Email: "u@example.com", Nickname: "U"},
			PasswordHash: "hash:correct horse battery",
		},
	}}
}

func assertServiceCode(t *testing.T, err error, code auth.ErrorCode) {
	t.Helper()
	var serviceErr *auth.ServiceError
	if !errors.As(err, &serviceErr) || serviceErr.Code != code {
		t.Fatalf("error = %v, want code %s", err, code)
	}
}
