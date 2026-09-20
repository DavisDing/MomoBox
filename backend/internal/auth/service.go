package auth

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

type ServiceConfig struct {
	RegistrationMode RegistrationMode
	AccessTokenTTL   time.Duration
	RefreshTokenTTL  time.Duration
	RefreshPepper    []byte
}

type Service struct {
	users       UserRepository
	refresh     RefreshTokenRepository
	memberships MembershipReader
	devices     DeviceReader
	hasher      PasswordHasher
	issuer      AccessTokenIssuer
	random      RandomTokenSource
	ids         IDGenerator
	clock       Clock
	config      ServiceConfig
	refreshHash HMACRefreshTokenHasher
}

func NewService(users UserRepository, refresh RefreshTokenRepository, memberships MembershipReader, devices DeviceReader, hasher PasswordHasher, issuer AccessTokenIssuer, random RandomTokenSource, ids IDGenerator, clock Clock, config ServiceConfig) (*Service, error) {
	if users == nil || refresh == nil || hasher == nil || issuer == nil || random == nil || ids == nil || clock == nil {
		return nil, errors.New("auth service dependencies must not be nil")
	}
	if config.RegistrationMode == "" {
		config.RegistrationMode = RegistrationFirstSetup
	}
	if config.AccessTokenTTL <= 0 {
		config.AccessTokenTTL = 15 * time.Minute
	}
	if config.RefreshTokenTTL <= 0 {
		config.RefreshTokenTTL = 30 * 24 * time.Hour
	}
	return &Service{users: users, refresh: refresh, memberships: memberships, devices: devices, hasher: hasher, issuer: issuer, random: random, ids: ids, clock: clock, config: config, refreshHash: HMACRefreshTokenHasher{Pepper: config.RefreshPepper}}, nil
}

func (s *Service) Register(ctx context.Context, request RegisterRequest) (AuthResponse, error) {
	var empty AuthResponse
	if err := validateRegistration(request); err != nil {
		return empty, err
	}
	mode := s.config.RegistrationMode
	count, err := s.users.Count(ctx)
	if err != nil {
		return empty, err
	}
	if mode == RegistrationInviteOnly || (mode == RegistrationFirstSetup && count > 0) {
		return empty, newError(CodeRegistrationClosed, "registration is not available")
	}
	if mode != RegistrationFirstSetup && mode != RegistrationOpen && mode != RegistrationInviteOnly {
		return empty, newError(CodeValidation, "unsupported registration mode")
	}
	normalizedEmail := NormalizeEmail(request.Email)
	passwordHash, err := s.hasher.Hash(request.Password)
	if err != nil {
		return empty, withCause(CodeValidation, "password cannot be processed", err)
	}
	userID, err := s.ids.NewID()
	if err != nil {
		return empty, err
	}
	stored := StoredUser{User: User{ID: userID, Email: normalizedEmail, Nickname: strings.TrimSpace(request.Nickname)}, PasswordHash: passwordHash}
	if err := s.users.Create(ctx, stored); err != nil {
		if hasCode(err, CodeEmailAlreadyExists) {
			return empty, err
		}
		return empty, err
	}
	return s.issueAuth(ctx, stored.User, "", "")
}

func (s *Service) Login(ctx context.Context, request LoginRequest) (AuthResponse, error) {
	var empty AuthResponse
	if strings.TrimSpace(request.Email) == "" || request.Password == "" {
		return empty, newError(CodeValidation, "email and password are required")
	}
	if request.Device != nil {
		if err := validateDevice(*request.Device); err != nil {
			return empty, err
		}
	}
	stored, err := s.users.FindByEmail(ctx, NormalizeEmail(request.Email))
	if err != nil || s.hasher.Compare(stored.PasswordHash, request.Password) != nil {
		return empty, newError(CodeInvalidCredentials, "email or password is invalid")
	}
	scope, _, err := s.currentScope(ctx, stored.ID)
	if err != nil {
		return empty, err
	}
	if request.Device != nil {
		if scope.FamilyID == "" {
			return empty, newError(CodeValidation, "a family must be selected before registering a sync device")
		}
		if s.devices != nil {
			if err := s.devices.UpsertDevice(ctx, DeviceRecord{ID: request.Device.DeviceID, UserID: stored.ID, FamilyID: scope.FamilyID, DeviceName: strings.TrimSpace(request.Device.DeviceName), Platform: request.Device.Platform, AppVersion: strings.TrimSpace(request.Device.AppVersion), CreatedAt: s.clock.Now()}); err != nil {
				return empty, err
			}
		}
	}
	return s.issueAuth(ctx, stored.User, deviceID(request.Device), scope.FamilyID)
}

func (s *Service) Refresh(ctx context.Context, request RefreshRequest) (AuthResponse, error) {
	var empty AuthResponse
	raw := strings.TrimSpace(request.RefreshToken)
	if len(raw) < 32 {
		return empty, newError(CodeInvalidToken, "refresh token is invalid")
	}
	record, err := s.refresh.FindByHash(ctx, s.refreshHash.Hash(raw))
	if err != nil {
		return empty, newError(CodeInvalidToken, "refresh token is invalid")
	}
	now := s.clock.Now()
	if record.RevokedAt != nil {
		return empty, newError(CodeRefreshRevoked, "refresh token has been revoked")
	}
	if !record.ExpiresAt.After(now) {
		return empty, newError(CodeTokenExpired, "refresh token has expired")
	}
	stored, err := s.users.FindByID(ctx, record.UserID)
	if err != nil {
		return empty, newError(CodeInvalidToken, "refresh token is invalid")
	}
	newRaw, err := s.random.RandomToken()
	if err != nil {
		return empty, err
	}
	newID, err := s.ids.NewID()
	if err != nil {
		return empty, err
	}
	scope, _, err := s.currentScope(ctx, stored.ID)
	if err != nil {
		return empty, err
	}
	deviceID := record.DeviceID
	if record.FamilyID == "" || record.FamilyID != scope.FamilyID {
		// A sync device is family-scoped. If the user's current family changed
		// after this refresh token was issued, the old device must not be
		// carried into a token for the new family. The client can register or
		// log in with a device again after selecting the new family.
		deviceID = ""
	}
	newRecord := RefreshTokenRecord{ID: newID, TokenHash: s.refreshHash.Hash(newRaw), UserID: record.UserID, FamilyID: scope.FamilyID, DeviceID: deviceID, CreatedAt: now, ExpiresAt: now.Add(s.config.RefreshTokenTTL)}
	access, err := s.issuer.Issue(AccessTokenClaims{UserID: stored.ID, FamilyID: scope.FamilyID, Role: scope.Role, DeviceID: deviceID, IssuedAt: now, ExpiresAt: now.Add(s.config.AccessTokenTTL)})
	if err != nil {
		return empty, err
	}
	if err := s.refresh.Rotate(ctx, record.TokenHash, newRecord, now); err != nil {
		return empty, err
	}
	return AuthResponse{User: stored.User, AccessToken: access, RefreshToken: newRaw, ExpiresIn: int64(s.config.AccessTokenTTL / time.Second)}, nil
}

func (s *Service) Logout(ctx context.Context, request RefreshRequest) error {
	raw := strings.TrimSpace(request.RefreshToken)
	if len(raw) < 32 {
		return newError(CodeInvalidToken, "refresh token is invalid")
	}
	hash := s.refreshHash.Hash(raw)
	record, err := s.refresh.FindByHash(ctx, hash)
	if err != nil {
		return newError(CodeInvalidToken, "refresh token is invalid")
	}
	now := s.clock.Now()
	if record.RevokedAt != nil {
		return newError(CodeRefreshRevoked, "refresh token has been revoked")
	}
	if !record.ExpiresAt.After(now) {
		return newError(CodeTokenExpired, "refresh token has expired")
	}
	return s.refresh.Revoke(ctx, hash, now)
}

func (s *Service) CurrentUser(ctx context.Context, accessToken string) (MeResponse, error) {
	var empty MeResponse
	claims, err := s.issuer.Verify(strings.TrimSpace(accessToken), s.clock.Now())
	if err != nil {
		return empty, newError(CodeInvalidToken, "access token is invalid")
	}
	stored, err := s.users.FindByID(ctx, claims.UserID)
	if err != nil {
		return empty, newError(CodeInvalidToken, "access token is invalid")
	}
	response := MeResponse{User: stored.User, Families: []FamilyMembership{}, Devices: []SyncDevice{}}
	if s.memberships != nil {
		response.Families, err = s.memberships.ListUserMemberships(ctx, stored.ID)
		if err != nil {
			return empty, err
		}
	}
	if s.devices != nil {
		response.Devices, err = s.devices.ListUserDevices(ctx, stored.ID)
		if err != nil {
			return empty, err
		}
	}
	return response, nil
}

func (s *Service) issueAuth(ctx context.Context, user User, deviceID, familyID string) (AuthResponse, error) {
	now := s.clock.Now()
	scope, _, err := s.currentScope(ctx, user.ID)
	if err != nil {
		return AuthResponse{}, err
	}
	if familyID != "" && scope.FamilyID != familyID {
		return AuthResponse{}, newError(CodeInvalidToken, "selected family is no longer available")
	}
	access, err := s.issuer.Issue(AccessTokenClaims{UserID: user.ID, FamilyID: scope.FamilyID, Role: scope.Role, DeviceID: deviceID, IssuedAt: now, ExpiresAt: now.Add(s.config.AccessTokenTTL)})
	if err != nil {
		return AuthResponse{}, err
	}
	rawRefresh, err := s.random.RandomToken()
	if err != nil {
		return AuthResponse{}, err
	}
	refreshID, err := s.ids.NewID()
	if err != nil {
		return AuthResponse{}, err
	}
	if err := s.refresh.Create(ctx, RefreshTokenRecord{ID: refreshID, TokenHash: s.refreshHash.Hash(rawRefresh), UserID: user.ID, FamilyID: scope.FamilyID, DeviceID: deviceID, CreatedAt: now, ExpiresAt: now.Add(s.config.RefreshTokenTTL)}); err != nil {
		return AuthResponse{}, err
	}
	return AuthResponse{User: user, AccessToken: access, RefreshToken: rawRefresh, ExpiresIn: int64(s.config.AccessTokenTTL / time.Second)}, nil
}

func (s *Service) currentScope(ctx context.Context, userID string) (FamilyMembership, bool, error) {
	if s.memberships == nil {
		return FamilyMembership{}, false, nil
	}
	membership, ok, err := s.memberships.CurrentUserMembership(ctx, userID)
	if err != nil {
		return FamilyMembership{}, false, err
	}
	if !ok {
		return FamilyMembership{}, false, nil
	}
	return membership, true, nil
}

func NormalizeEmail(email string) string { return strings.ToLower(strings.TrimSpace(email)) }

func validateRegistration(request RegisterRequest) error {
	if !validEmail(request.Email) {
		return newError(CodeValidation, "email is invalid")
	}
	passwordLength := utf8.RuneCountInString(request.Password)
	if passwordLength < 12 || passwordLength > 128 {
		return newError(CodeValidation, "password must be 12-128 characters")
	}
	if n := utf8.RuneCountInString(strings.TrimSpace(request.Nickname)); n < 1 || n > 80 {
		return newError(CodeValidation, "nickname must be 1-80 characters")
	}
	if request.Device != nil {
		return newError(CodeValidation, "device registration is only available after joining a family")
	}
	return nil
}

func validEmail(email string) bool {
	email = NormalizeEmail(email)
	at := strings.LastIndexByte(email, '@')
	return at > 0 && at < len(email)-1 && !strings.ContainsAny(email[at+1:], " @")
}

func validateDevice(device RegisterDeviceRequest) error {
	if strings.TrimSpace(device.DeviceID) == "" || utf8.RuneCountInString(strings.TrimSpace(device.DeviceName)) < 1 || utf8.RuneCountInString(strings.TrimSpace(device.DeviceName)) > 120 {
		return newError(CodeValidation, "device is invalid")
	}
	if device.Platform != "android" && device.Platform != "ios" && device.Platform != "other" {
		return newError(CodeValidation, "device platform is invalid")
	}
	return nil
}

func deviceID(device *RegisterDeviceRequest) string {
	if device == nil {
		return ""
	}
	return strings.TrimSpace(device.DeviceID)
}
