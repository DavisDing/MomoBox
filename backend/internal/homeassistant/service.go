package homeassistant

import (
	"context"
	cryptorand "crypto/rand"
	"encoding/hex"
	"errors"
	"strings"
	"time"
)

// Service contains Home Assistant business rules only. HTTP routing, JWT
// parsing, SQL, encryption implementation, and network I/O belong elsewhere.
type Service struct {
	Integrations IntegrationRepository
	Devices      DeviceRepository
	Entities     EntityRepository
	Permissions  PermissionRepository
	Audit        AuditRepository
	Cipher       TokenCipher
	Client       Client
	Now          func() time.Time
}

// NewService wires the business service to persistence, encryption, audit, and
// the external-client contracts. The supplied Client is still only an
// interface; this package never constructs an HTTP client.
func NewService(integrations IntegrationRepository, devices DeviceRepository, entities EntityRepository, permissions PermissionRepository, audit AuditRepository, cipher TokenCipher, client Client) *Service {
	return &Service{Integrations: integrations, Devices: devices, Entities: entities, Permissions: permissions, Audit: audit, Cipher: cipher, Client: client}
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now().UTC()
	}
	return time.Now().UTC()
}

func (s *Service) readyFor(needIntegrations, needDevices, needEntities, needPermissions, needAudit, needCipher, needClient bool) error {
	if (needIntegrations && s.Integrations == nil) ||
		(needDevices && s.Devices == nil) ||
		(needEntities && s.Entities == nil) ||
		(needPermissions && s.Permissions == nil) ||
		(needAudit && s.Audit == nil) ||
		(needCipher && s.Cipher == nil) ||
		(needClient && s.Client == nil) {
		return businessError(CodeInvalidArgument, "home assistant service dependencies are incomplete", nil)
	}
	return nil
}

func (s *Service) CreateIntegration(ctx context.Context, actor Actor, req AddIntegrationRequest) (IntegrationDTO, error) {
	if err := s.readyFor(true, false, false, false, false, true, false); err != nil {
		return IntegrationDTO{}, err
	}
	if err := validateActor(actor); err != nil {
		return IntegrationDTO{}, err
	}
	if !actor.Role.CanManageIntegration() {
		return IntegrationDTO{}, businessError(CodeForbidden, "only owner or admin can configure Home Assistant", nil)
	}
	if err := validateName(req.Name); err != nil {
		return IntegrationDTO{}, err
	}
	if err := ValidateBaseURL(req.BaseURL); err != nil {
		return IntegrationDTO{}, err
	}
	if err := ValidateAccessToken(req.AccessToken); err != nil {
		return IntegrationDTO{}, err
	}
	ciphertext, version, err := s.Cipher.Encrypt(ctx, strings.TrimSpace(req.AccessToken))
	if err != nil {
		return IntegrationDTO{}, businessError(CodeInvalidToken, "access_token could not be protected", err)
	}
	now := s.now()
	integration := Integration{ID: newID(), FamilyID: actor.FamilyID, Name: strings.TrimSpace(req.Name), BaseURL: NormalizeBaseURL(req.BaseURL), AccessTokenCiphertext: append([]byte(nil), ciphertext...), KeyVersion: version, Status: IntegrationUnknown, CreatedAt: now, UpdatedAt: now, Enabled: true}
	if err := s.Integrations.Create(ctx, integration); err != nil {
		return IntegrationDTO{}, err
	}
	return integrationDTO(integration), nil
}

func (s *Service) ListIntegrations(ctx context.Context, actor Actor) ([]IntegrationDTO, error) {
	if err := s.readyFor(true, false, false, false, false, false, false); err != nil {
		return nil, err
	}
	if err := validateActor(actor); err != nil {
		return nil, err
	}
	items, err := s.Integrations.List(ctx, actor.FamilyID)
	if err != nil {
		return nil, err
	}
	result := make([]IntegrationDTO, 0, len(items))
	for _, item := range items {
		if item.FamilyID == actor.FamilyID {
			result = append(result, integrationDTO(item))
		}
	}
	return result, nil
}

func (s *Service) UpdateIntegration(ctx context.Context, actor Actor, integrationID string, req UpdateIntegrationRequest) (IntegrationDTO, error) {
	if err := s.readyFor(true, false, false, false, false, true, false); err != nil {
		return IntegrationDTO{}, err
	}
	if err := validateActor(actor); err != nil {
		return IntegrationDTO{}, err
	}
	if !actor.Role.CanManageIntegration() {
		return IntegrationDTO{}, businessError(CodeForbidden, "only owner or admin can configure Home Assistant", nil)
	}
	if err := validateIntegrationID(integrationID); err != nil {
		return IntegrationDTO{}, err
	}
	integration, err := s.Integrations.Get(ctx, actor.FamilyID, integrationID)
	if err != nil {
		return IntegrationDTO{}, err
	}
	if integration.FamilyID != actor.FamilyID {
		return IntegrationDTO{}, businessError(CodeNotFound, "Home Assistant integration was not found", nil)
	}
	if req.Name != nil {
		if err := validateName(*req.Name); err != nil {
			return IntegrationDTO{}, err
		}
		integration.Name = strings.TrimSpace(*req.Name)
	}
	if req.BaseURL != nil {
		if err := ValidateBaseURL(*req.BaseURL); err != nil {
			return IntegrationDTO{}, err
		}
		integration.BaseURL = NormalizeBaseURL(*req.BaseURL)
	}
	if req.AccessToken != nil {
		if err := ValidateAccessToken(*req.AccessToken); err != nil {
			return IntegrationDTO{}, err
		}
		ciphertext, version, cipherErr := s.Cipher.Encrypt(ctx, strings.TrimSpace(*req.AccessToken))
		if cipherErr != nil {
			return IntegrationDTO{}, businessError(CodeInvalidToken, "access_token could not be protected", cipherErr)
		}
		integration.AccessTokenCiphertext = append([]byte(nil), ciphertext...)
		integration.KeyVersion = version
	}
	if req.Enabled != nil {
		integration.Enabled = *req.Enabled
		if !integration.Enabled {
			integration.Status = IntegrationDisabled
		} else if integration.Status == IntegrationDisabled {
			integration.Status = IntegrationUnknown
		}
	}
	integration.UpdatedAt = s.now()
	if err := s.Integrations.Update(ctx, actor.FamilyID, integration); err != nil {
		return IntegrationDTO{}, err
	}
	return integrationDTO(integration), nil
}

func (s *Service) DeleteIntegration(ctx context.Context, actor Actor, integrationID string) error {
	if err := s.readyFor(true, false, false, false, false, false, false); err != nil {
		return err
	}
	if err := validateActor(actor); err != nil {
		return err
	}
	if !actor.Role.CanManageIntegration() {
		return businessError(CodeForbidden, "only owner or admin can configure Home Assistant", nil)
	}
	if err := validateIntegrationID(integrationID); err != nil {
		return err
	}
	integration, err := s.Integrations.Get(ctx, actor.FamilyID, integrationID)
	if err != nil {
		return err
	}
	if integration.FamilyID != actor.FamilyID {
		return businessError(CodeNotFound, "Home Assistant integration was not found", nil)
	}
	return s.Integrations.Delete(ctx, actor.FamilyID, integrationID)
}

func (s *Service) integrationWithToken(ctx context.Context, familyID, integrationID string) (Integration, string, error) {
	if err := validateIntegrationID(integrationID); err != nil {
		return Integration{}, "", err
	}
	integration, err := s.Integrations.Get(ctx, familyID, integrationID)
	if err != nil {
		return Integration{}, "", err
	}
	if integration.FamilyID != familyID {
		return Integration{}, "", businessError(CodeNotFound, "Home Assistant integration was not found", nil)
	}
	if err := ValidateBaseURL(integration.BaseURL); err != nil {
		return Integration{}, "", err
	}
	if !integration.Enabled || integration.Status == IntegrationDisabled {
		return Integration{}, "", businessError(CodeNotConfigured, "Home Assistant integration is disabled", nil)
	}
	if len(integration.AccessTokenCiphertext) == 0 || integration.KeyVersion == "" {
		return Integration{}, "", businessError(CodeNotConfigured, "Home Assistant integration is not configured", nil)
	}
	token, err := s.Cipher.Decrypt(ctx, integration.AccessTokenCiphertext, integration.KeyVersion)
	if err != nil {
		return Integration{}, "", businessError(CodeInvalidToken, "Home Assistant token could not be decrypted", err)
	}
	token = strings.TrimSpace(token)
	if err := ValidateAccessToken(token); err != nil {
		return Integration{}, "", businessError(CodeInvalidToken, "Home Assistant token is invalid", nil)
	}
	return integration, token, nil
}

func (s *Service) TestIntegration(ctx context.Context, actor Actor, integrationID string) (ConnectionTestDTO, error) {
	if err := s.readyFor(true, false, false, false, false, true, true); err != nil {
		return ConnectionTestDTO{}, err
	}
	if err := validateActor(actor); err != nil {
		return ConnectionTestDTO{}, err
	}
	if !actor.Role.CanManageIntegration() {
		return ConnectionTestDTO{}, businessError(CodeForbidden, "only owner or admin can test Home Assistant", nil)
	}
	integration, token, err := s.integrationWithToken(ctx, actor.FamilyID, integrationID)
	if err != nil {
		return ConnectionTestDTO{}, err
	}
	checkedAt := s.now()
	result, clientErr := s.Client.Test(ctx, integration.BaseURL, token)
	integration.LastCheckedAt = &checkedAt
	if clientErr != nil {
		integration.Status = IntegrationUnavailable
	} else if result.Connected {
		integration.Status = IntegrationHealthy
	} else if result.ErrorCode == "invalid_credentials" {
		integration.Status = IntegrationInvalidCredentials
	} else {
		integration.Status = IntegrationUnavailable
	}
	integration.UpdatedAt = checkedAt
	updateErr := s.Integrations.Update(ctx, actor.FamilyID, integration)
	if updateErr != nil {
		if clientErr != nil {
			return ConnectionTestDTO{}, businessError(CodeIntegrationUnavailable, "Home Assistant connection failed and status could not be saved", updateErr)
		}
		return ConnectionTestDTO{}, updateErr
	}
	if clientErr != nil {
		return ConnectionTestDTO{}, businessError(CodeIntegrationUnavailable, "Home Assistant connection failed", clientErr)
	}
	return ConnectionTestDTO{Connected: result.Connected, CheckedAt: checkedAt, ServerVersion: result.ServerVersion, ErrorCode: result.ErrorCode}, nil
}

func (s *Service) Discover(ctx context.Context, actor Actor, integrationID string) (DiscoveryDTO, error) {
	if err := s.readyFor(true, true, true, false, false, true, true); err != nil {
		return DiscoveryDTO{}, err
	}
	if err := validateActor(actor); err != nil {
		return DiscoveryDTO{}, err
	}
	if !actor.Role.CanManageIntegration() {
		return DiscoveryDTO{}, businessError(CodeForbidden, "only owner or admin can discover Home Assistant", nil)
	}
	integration, token, err := s.integrationWithToken(ctx, actor.FamilyID, integrationID)
	if err != nil {
		return DiscoveryDTO{}, err
	}
	discovery, err := s.Client.Discover(ctx, integration.BaseURL, token)
	if err != nil {
		return DiscoveryDTO{}, businessError(CodeIntegrationUnavailable, "Home Assistant discovery failed", err)
	}
	now := s.now()
	devices := make([]HADevice, 0, len(discovery.Devices))
	deviceIDs := make(map[string]string, len(discovery.Devices))
	for _, item := range discovery.Devices {
		if strings.TrimSpace(item.HADeviceID) == "" {
			continue
		}
		id := newID()
		deviceIDs[item.HADeviceID] = id
		devices = append(devices, HADevice{ID: id, FamilyID: actor.FamilyID, IntegrationID: integration.ID, HADeviceID: item.HADeviceID, Name: item.Name, AreaName: item.AreaName, Manufacturer: item.Manufacturer, Model: item.Model, Enabled: true, CreatedAt: now, UpdatedAt: now})
	}
	entities := make([]HAEntity, 0, len(discovery.Entities))
	for _, item := range discovery.Entities {
		if validateEntityID(item.EntityID) != nil || strings.TrimSpace(item.Domain) == "" {
			continue
		}
		deviceID := ""
		if item.HADeviceID != "" {
			deviceID = deviceIDs[item.HADeviceID]
			if deviceID == "" {
				continue
			} // reject an entity that points at an undiscovered device
		}
		// HA scenes and scripts commonly have no device_id. They remain valid
		// entities and must be discoverable so owner/admin can explicitly
		// whitelist activate_scene/run_script for them.
		entities = append(entities, HAEntity{ID: newID(), FamilyID: actor.FamilyID, IntegrationID: integration.ID, DeviceID: deviceID, EntityID: item.EntityID, Domain: strings.ToLower(strings.TrimSpace(item.Domain)), Name: item.Name, AreaName: item.AreaName, Capabilities: normalizeCapabilities(item.Capabilities), HVACModes: normalizeCapabilities(item.HVACModes), TemperatureMin: cloneFloat(item.TemperatureMin), TemperatureMax: cloneFloat(item.TemperatureMax), CurrentState: item.CurrentState, IsVisible: true, IsControllable: discoveredControllable(item), CreatedAt: now, UpdatedAt: now})
	}
	if err := s.Devices.ReplaceForIntegration(ctx, actor.FamilyID, integration.ID, devices); err != nil {
		return DiscoveryDTO{}, err
	}
	if err := s.Entities.ReplaceForIntegration(ctx, actor.FamilyID, integration.ID, entities); err != nil {
		return DiscoveryDTO{}, err
	}
	return DiscoveryDTO{IntegrationID: integration.ID, Devices: len(devices), Entities: len(entities)}, nil
}

func (s *Service) ListEntities(ctx context.Context, actor Actor, integrationID string, controllableOnly bool) ([]EntityDTO, error) {
	if err := s.readyFor(true, false, true, true, false, false, false); err != nil {
		return nil, err
	}
	if err := validateActor(actor); err != nil {
		return nil, err
	}
	if integrationID != "" {
		if err := validateIntegrationID(integrationID); err != nil {
			return nil, err
		}
		integration, err := s.Integrations.Get(ctx, actor.FamilyID, integrationID)
		if err != nil {
			return nil, err
		}
		if integration.FamilyID != actor.FamilyID {
			return nil, businessError(CodeNotFound, "Home Assistant integration was not found", nil)
		}
	}
	entities, err := s.Entities.List(ctx, actor.FamilyID, integrationID)
	if err != nil {
		return nil, err
	}
	result := make([]EntityDTO, 0, len(entities))
	for _, entity := range entities {
		if entity.FamilyID != actor.FamilyID || (integrationID != "" && entity.IntegrationID != integrationID) {
			continue
		}
		permission, permissionErr := s.Permissions.Get(ctx, actor.FamilyID, entity.IntegrationID, entity.EntityID, actor.Role)
		if permissionErr != nil {
			if isNotFound(permissionErr) {
				continue
			}
			return nil, permissionErr
		}
		if !permission.CanView || !entity.IsVisible || (controllableOnly && (!permission.CanControl || !entity.IsControllable)) {
			continue
		}
		result = append(result, entityDTO(entity))
	}
	return result, nil
}

func (s *Service) GetState(ctx context.Context, actor Actor, integrationID, entityID string) (StateDTO, error) {
	if err := s.readyFor(true, false, true, true, false, true, true); err != nil {
		return StateDTO{}, err
	}
	if err := validateActor(actor); err != nil {
		return StateDTO{}, err
	}
	if err := validateIntegrationID(integrationID); err != nil {
		return StateDTO{}, err
	}
	if err := validateEntityID(entityID); err != nil {
		return StateDTO{}, err
	}
	entity, err := s.Entities.Get(ctx, actor.FamilyID, integrationID, entityID)
	if err != nil {
		return StateDTO{}, err
	}
	if entity.FamilyID != actor.FamilyID || entity.IntegrationID != integrationID {
		return StateDTO{}, businessError(CodeNotFound, "Home Assistant entity was not found", nil)
	}
	permission, err := s.Permissions.Get(ctx, actor.FamilyID, entity.IntegrationID, entity.EntityID, actor.Role)
	if err != nil {
		return StateDTO{}, err
	}
	if !permission.CanView || !entity.IsVisible {
		return StateDTO{}, businessError(CodeForbidden, "entity is not visible to this member", nil)
	}
	integration, token, err := s.integrationWithToken(ctx, actor.FamilyID, entity.IntegrationID)
	if err != nil {
		return StateDTO{}, err
	}
	state, err := s.Client.GetState(ctx, integration.BaseURL, token, entity)
	if err != nil {
		return StateDTO{}, businessError(CodeIntegrationUnavailable, "Home Assistant state could not be read", err)
	}
	return *stateDTO(&state), nil
}

func (s *Service) ExecuteCommand(ctx context.Context, actor Actor, integrationID, entityID string, req CommandRequest) (CommandDTO, error) {
	if err := s.readyFor(true, false, true, true, true, true, true); err != nil {
		return CommandDTO{}, err
	}
	if err := validateActor(actor); err != nil {
		return CommandDTO{}, err
	}
	if err := validateIntegrationID(integrationID); err != nil {
		return CommandDTO{}, err
	}
	if err := validateEntityID(entityID); err != nil {
		return CommandDTO{}, err
	}
	if err := validateCommandRequest(req); err != nil {
		return CommandDTO{}, err
	}
	entity, err := s.Entities.Get(ctx, actor.FamilyID, integrationID, entityID)
	if err != nil {
		return CommandDTO{}, err
	}
	if entity.FamilyID != actor.FamilyID || entity.IntegrationID != integrationID {
		return CommandDTO{}, businessError(CodeNotFound, "Home Assistant entity was not found", nil)
	}
	permission, permissionErr := s.Permissions.Get(ctx, actor.FamilyID, entity.IntegrationID, entity.EntityID, actor.Role)
	if permissionErr != nil {
		// A missing role/entity whitelist is a denied command attempt. Keep the
		// external error semantics unchanged while still recording the audit
		// contract after the entity has been resolved.
		if isNotFound(permissionErr) {
			if auditErr := s.appendAudit(ctx, actor, entity, req, AuditDenied, string(CodeForbidden)); auditErr != nil {
				return CommandDTO{}, auditErr
			}
		}
		return CommandDTO{}, permissionErr
	}
	if !permission.CanControl || !entity.IsControllable || !commandInPermission(req.Command, permission.AllowedCommands) {
		if auditErr := s.appendAudit(ctx, actor, entity, req, AuditDenied, string(CodeForbidden)); auditErr != nil {
			return CommandDTO{}, auditErr
		}
		return CommandDTO{}, businessError(CodeForbidden, "member is not allowed to control this entity with this command", nil)
	}
	if !commandAllowedForEntity(entity, req.Command, req.Parameters) {
		if auditErr := s.appendAudit(ctx, actor, entity, req, AuditDenied, string(CodeUnsupportedCommand)); auditErr != nil {
			return CommandDTO{}, auditErr
		}
		return CommandDTO{}, businessError(CodeUnsupportedCommand, "command is not supported by the entity capabilities", nil)
	}
	integration, token, integrationErr := s.integrationWithToken(ctx, actor.FamilyID, entity.IntegrationID)
	if integrationErr != nil {
		if auditErr := s.appendAudit(ctx, actor, entity, req, AuditFailed, string(errorCode(integrationErr))); auditErr != nil {
			return CommandDTO{}, auditErr
		}
		return CommandDTO{}, integrationErr
	}
	invocation := CommandInvocation{EntityID: entity.EntityID, Domain: entity.Domain, Command: req.Command, Parameters: req.Parameters}
	result, clientErr := s.Client.Execute(ctx, integration.BaseURL, token, invocation)
	resultKind := AuditSucceeded
	errorCode := ""
	if clientErr != nil {
		resultKind = AuditFailed
		errorCode = string(CodeIntegrationUnavailable)
	} else if !result.Accepted {
		resultKind = AuditFailed
		errorCode = "HA_COMMAND_REJECTED"
	}
	if auditErr := s.appendAudit(ctx, actor, entity, req, resultKind, errorCode); auditErr != nil {
		return CommandDTO{}, auditErr
	}
	if clientErr != nil {
		return CommandDTO{}, businessError(CodeIntegrationUnavailable, "Home Assistant command failed", clientErr)
	}
	if !result.Accepted {
		return CommandDTO{}, businessError(CodeIntegrationUnavailable, "Home Assistant rejected the command", nil)
	}
	return CommandDTO{Accepted: true, EntityID: entity.EntityID, Command: req.Command, ExecutedAt: s.now(), State: stateDTO(result.State)}, nil
}

func (s *Service) ListPermissions(ctx context.Context, actor Actor) ([]PermissionDTO, error) {
	if err := s.readyFor(false, false, false, true, false, false, false); err != nil {
		return nil, err
	}
	if err := validateActor(actor); err != nil {
		return nil, err
	}
	items, err := s.Permissions.List(ctx, actor.FamilyID)
	if err != nil {
		return nil, err
	}
	result := make([]PermissionDTO, 0, len(items))
	for _, item := range items {
		if item.FamilyID == actor.FamilyID {
			result = append(result, permissionDTO(item))
		}
	}
	return result, nil
}

func (s *Service) UpdatePermission(ctx context.Context, actor Actor, req PermissionRequest) (PermissionDTO, error) {
	if err := s.readyFor(false, false, true, true, false, false, false); err != nil {
		return PermissionDTO{}, err
	}
	if err := validateActor(actor); err != nil {
		return PermissionDTO{}, err
	}
	if !actor.Role.CanManagePermissions() {
		return PermissionDTO{}, businessError(CodeForbidden, "only owner or admin can modify Home Assistant permissions", nil)
	}
	if !req.Role.Valid() {
		return PermissionDTO{}, businessError(CodeInvalidRole, "role is invalid", nil)
	}
	if err := validateIntegrationID(req.IntegrationID); err != nil {
		return PermissionDTO{}, err
	}
	if err := validateEntityID(req.EntityID); err != nil {
		return PermissionDTO{}, err
	}
	if !req.CanControl && len(req.AllowedCommands) > 0 {
		return PermissionDTO{}, businessError(CodeInvalidParameters, "allowed_commands requires can_control", nil)
	}
	for _, command := range req.AllowedCommands {
		if !command.Valid() {
			return PermissionDTO{}, businessError(CodeInvalidCommand, "permission contains a command outside the whitelist", nil)
		}
	}
	entity, err := s.Entities.Get(ctx, actor.FamilyID, req.IntegrationID, req.EntityID)
	if err != nil {
		return PermissionDTO{}, err
	}
	if entity.FamilyID != actor.FamilyID || entity.IntegrationID != req.IntegrationID {
		return PermissionDTO{}, businessError(CodeNotFound, "Home Assistant entity was not found", nil)
	}
	permission := EntityPermission{FamilyID: actor.FamilyID, IntegrationID: entity.IntegrationID, EntityID: entity.EntityID, Role: req.Role, CanView: req.CanView, CanControl: req.CanControl, AllowedCommands: append([]Command(nil), req.AllowedCommands...)}
	if err := s.Permissions.Upsert(ctx, permission); err != nil {
		return PermissionDTO{}, err
	}
	return permissionDTO(permission), nil
}

func (s *Service) appendAudit(ctx context.Context, actor Actor, entity HAEntity, req CommandRequest, result AuditResult, errorCode string) error {
	log := CommandAuditLog{FamilyID: actor.FamilyID, IntegrationID: entity.IntegrationID, EntityID: entity.EntityID, RequestedBy: actor.UserID, Command: req.Command, SafeParametersSummary: safeParameters(req.Parameters), Result: result, ErrorCode: errorCode, CreatedAt: s.now(), RequestID: req.RequestID}
	if err := s.Audit.Append(ctx, log); err != nil {
		return businessError(CodeAuditFailure, "Home Assistant command audit could not be recorded", err)
	}
	return nil
}

func permissionDTO(p EntityPermission) PermissionDTO {
	return PermissionDTO{IntegrationID: p.IntegrationID, EntityID: p.EntityID, Role: p.Role, CanView: p.CanView, CanControl: p.CanControl, AllowedCommands: append([]Command(nil), p.AllowedCommands...)}
}

func normalizeCapabilities(values []string) []string {
	seen := map[string]struct{}{}
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.ToLower(strings.TrimSpace(value))
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func newID() string {
	var bytes [16]byte
	if _, err := cryptorand.Read(bytes[:]); err != nil {
		// crypto/rand failure is exceptionally rare. The value remains unique
		// enough for an in-memory service fallback and never contains a secret.
		return "00000000-0000-4000-8000-" + hex.EncodeToString(bytes[6:])
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	return hex.EncodeToString(bytes[0:4]) + "-" + hex.EncodeToString(bytes[4:6]) + "-" + hex.EncodeToString(bytes[6:8]) + "-" + hex.EncodeToString(bytes[8:10]) + "-" + hex.EncodeToString(bytes[10:16])
}

func discoveredControllable(item DiscoveredEntity) bool {
	domain := strings.ToLower(strings.TrimSpace(item.Domain))
	if domain == "scene" || domain == "script" {
		return true
	}
	if len(item.Capabilities) == 0 {
		return false
	}
	for _, capability := range item.Capabilities {
		switch strings.ToLower(strings.TrimSpace(capability)) {
		case "turn_on", "turn_off", "toggle", "on_off", "power", "switch", "brightness", "temperature", "temperature_control", "hvac_mode", "hvac_modes", "play", "pause", "media_playback", "play_pause":
			return true
		}
	}
	return false
}

func isNotFound(err error) bool {
	var business *BusinessError
	return errors.As(err, &business) && business.Code == CodeNotFound
}

func errorCode(err error) ErrorCode {
	var business *BusinessError
	if errors.As(err, &business) && business.Code != "" {
		return business.Code
	}
	return CodeIntegrationUnavailable
}
