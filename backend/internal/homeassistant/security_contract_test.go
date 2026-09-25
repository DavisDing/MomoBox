package homeassistant

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

const contractRequestID = "123e4567-e89b-12d3-a456-426614174000"

// These fakes intentionally return records independently of the supplied
// family in Get/List. That makes the service-level family checks observable,
// while the recorded arguments verify that the family is always propagated to
// the repository boundary.
type contractIntegrationRepo struct {
	items      map[string]Integration
	getFamilies []string
	listFamilies []string
	updates    []Integration
	deletes    []string
}

func (r *contractIntegrationRepo) Create(_ context.Context, item Integration) error {
	if r.items == nil { r.items = map[string]Integration{} }
	r.items[item.ID] = item
	return nil
}
func (r *contractIntegrationRepo) Get(_ context.Context, familyID, id string) (Integration, error) {
	r.getFamilies = append(r.getFamilies, familyID)
	item, ok := r.items[id]
	if !ok { return Integration{}, businessError(CodeNotFound, "integration not found", nil) }
	return item, nil
}
func (r *contractIntegrationRepo) List(_ context.Context, familyID string) ([]Integration, error) {
	r.listFamilies = append(r.listFamilies, familyID)
	result := make([]Integration, 0, len(r.items))
	for _, item := range r.items { result = append(result, item) }
	return result, nil
}
func (r *contractIntegrationRepo) Update(_ context.Context, familyID string, item Integration) error {
	r.updates = append(r.updates, item)
	if _, ok := r.items[item.ID]; !ok { return businessError(CodeNotFound, "integration not found", nil) }
	r.items[item.ID] = item
	_ = familyID
	return nil
}
func (r *contractIntegrationRepo) Delete(_ context.Context, familyID, id string) error {
	r.deletes = append(r.deletes, id)
	if _, ok := r.items[id]; !ok { return businessError(CodeNotFound, "integration not found", nil) }
	delete(r.items, id)
	_ = familyID
	return nil
}

type contractDeviceRepo struct{}
func (contractDeviceRepo) ReplaceForIntegration(context.Context, string, string, []HADevice) error { return nil }
func (contractDeviceRepo) List(context.Context, string, string) ([]HADevice, error) { return nil, nil }

type contractEntityRepo struct {
	items map[string]HAEntity
	getFamilies []string
	listFamilies []string
}
func entityKey(integrationID, entityID string) string { return integrationID + "\x00" + entityID }
func (r *contractEntityRepo) ReplaceForIntegration(_ context.Context, familyID, integrationID string, values []HAEntity) error {
	if r.items == nil { r.items = map[string]HAEntity{} }
	for _, value := range values { r.items[entityKey(integrationID, value.EntityID)] = value }
	_ = familyID
	return nil
}
func (r *contractEntityRepo) Get(_ context.Context, familyID, integrationID, entityID string) (HAEntity, error) {
	r.getFamilies = append(r.getFamilies, familyID)
	value, ok := r.items[entityKey(integrationID, entityID)]
	if !ok { return HAEntity{}, businessError(CodeNotFound, "entity not found", nil) }
	return value, nil
}
func (r *contractEntityRepo) List(_ context.Context, familyID, integrationID string) ([]HAEntity, error) {
	r.listFamilies = append(r.listFamilies, familyID)
	result := make([]HAEntity, 0, len(r.items))
	for _, value := range r.items {
		if integrationID == "" || value.IntegrationID == integrationID { result = append(result, value) }
	}
	return result, nil
}

type contractPermissionRepo struct {
	items map[string]EntityPermission
	getFamilies []string
	listFamilies []string
	upserts []EntityPermission
}
func permissionKey(familyID, integrationID, entityID string, role Role) string {
	return familyID + "\x00" + integrationID + "\x00" + entityID + "\x00" + string(role)
}
func (r *contractPermissionRepo) Get(_ context.Context, familyID, integrationID, entityID string, role Role) (EntityPermission, error) {
	r.getFamilies = append(r.getFamilies, familyID)
	value, ok := r.items[permissionKey(familyID, integrationID, entityID, role)]
	if !ok { return EntityPermission{}, businessError(CodeNotFound, "permission not found", nil) }
	return value, nil
}
func (r *contractPermissionRepo) List(_ context.Context, familyID string) ([]EntityPermission, error) {
	r.listFamilies = append(r.listFamilies, familyID)
	result := make([]EntityPermission, 0, len(r.items))
	for _, value := range r.items { result = append(result, value) }
	return result, nil
}
func (r *contractPermissionRepo) Upsert(_ context.Context, value EntityPermission) error {
	if r.items == nil { r.items = map[string]EntityPermission{} }
	r.items[permissionKey(value.FamilyID, value.IntegrationID, value.EntityID, value.Role)] = value
	r.upserts = append(r.upserts, value)
	return nil
}

type contractAuditRepo struct {
	logs []CommandAuditLog
	err error
}
func (r *contractAuditRepo) Append(_ context.Context, log CommandAuditLog) error {
	if r.err != nil { return r.err }
	r.logs = append(r.logs, log)
	return nil
}

type contractCipher struct {
	encrypted []byte
	version string
	plaintext string
	encryptInput string
	decryptInput []byte
	decryptVersion string
	err error
}
func (c *contractCipher) Encrypt(_ context.Context, plaintext string) ([]byte, string, error) {
	c.encryptInput = plaintext
	if c.err != nil { return nil, "", c.err }
	return append([]byte(nil), c.encrypted...), c.version, nil
}
func (c *contractCipher) Decrypt(_ context.Context, ciphertext []byte, version string) (string, error) {
	c.decryptInput = append([]byte(nil), ciphertext...)
	c.decryptVersion = version
	if c.err != nil { return "", c.err }
	return c.plaintext, nil
}

type contractHAClient struct {
	testCalls, discoverCalls, stateCalls, executeCalls int
	lastToken string
	lastInvocation CommandInvocation
	executeErr error
	stateErr error
}
func (c *contractHAClient) Test(context.Context, string, string) (ConnectionResult, error) { c.testCalls++; return ConnectionResult{Connected: true}, nil }
func (c *contractHAClient) Discover(context.Context, string, string) (Discovery, error) { c.discoverCalls++; return Discovery{}, nil }
func (c *contractHAClient) GetState(_ context.Context, _ string, token string, _ HAEntity) (HAState, error) {
	c.stateCalls++; c.lastToken = token
	if c.stateErr != nil { return HAState{}, c.stateErr }
	return HAState{EntityID: "light.kitchen", State: "on", FetchedAt: time.Now().UTC()}, nil
}
func (c *contractHAClient) Execute(_ context.Context, _ string, token string, invocation CommandInvocation) (CommandResult, error) {
	c.executeCalls++; c.lastToken = token; c.lastInvocation = invocation
	if c.executeErr != nil { return CommandResult{}, c.executeErr }
	return CommandResult{Accepted: true}, nil
}

func contractService(integration Integration, entity HAEntity, permissions ...EntityPermission) (*Service, *contractIntegrationRepo, *contractEntityRepo, *contractPermissionRepo, *contractAuditRepo, *contractCipher, *contractHAClient) {
	integrations := &contractIntegrationRepo{items: map[string]Integration{integration.ID: integration}}
	entities := &contractEntityRepo{items: map[string]HAEntity{entityKey(entity.IntegrationID, entity.EntityID): entity}}
	permissionRepo := &contractPermissionRepo{items: map[string]EntityPermission{}}
	for _, permission := range permissions { permissionRepo.items[permissionKey(permission.FamilyID, permission.IntegrationID, permission.EntityID, permission.Role)] = permission }
	audit := &contractAuditRepo{}
	cipher := &contractCipher{encrypted: []byte("ciphertext"), version: "v1", plaintext: "secret-token-123456"}
	client := &contractHAClient{}
	service := NewService(integrations, contractDeviceRepo{}, entities, permissionRepo, audit, cipher, client)
	service.Now = func() time.Time { return time.Date(2026, 9, 25, 0, 0, 0, time.UTC) }
	return service, integrations, entities, permissionRepo, audit, cipher, client
}

func contractIntegration(familyID, id string) Integration {
	return Integration{ID: id, FamilyID: familyID, Name: "Home", BaseURL: "http://ha.local", AccessTokenCiphertext: []byte("ciphertext"), KeyVersion: "v1", Status: IntegrationHealthy, Enabled: true}
}
func contractEntity(familyID, integrationID, entityID string) HAEntity {
	return HAEntity{ID: "row-" + entityID, FamilyID: familyID, IntegrationID: integrationID, EntityID: entityID, Domain: "light", Capabilities: []string{"on_off", "brightness"}, IsVisible: true, IsControllable: true}
}
func contractPermission(familyID, integrationID, entityID string, role Role, commands ...Command) EntityPermission {
	return EntityPermission{FamilyID: familyID, IntegrationID: integrationID, EntityID: entityID, Role: role, CanView: true, CanControl: true, AllowedCommands: commands}
}
func businessCode(t *testing.T, err error) ErrorCode {
	t.Helper()
	var value *BusinessError
	if !errors.As(err, &value) { t.Fatalf("error = %T %v, want BusinessError", err, err) }
	return value.Code
}

func TestIntegrationManagementOwnerAdminMemberAndFamilyIsolation(t *testing.T) {
	integration := contractIntegration("family-a", "integration-a")
	service, integrations, _, _, _, _, _ := contractService(integration, contractEntity("family-a", integration.ID, "light.kitchen"))
	owner := Actor{UserID: "owner", FamilyID: "family-a", Role: RoleOwner}
	admin := Actor{UserID: "admin", FamilyID: "family-a", Role: RoleAdmin}
	member := Actor{UserID: "member", FamilyID: "family-a", Role: RoleMember}

	created, err := service.CreateIntegration(context.Background(), owner, AddIntegrationRequest{Name: "New", BaseURL: "http://ha.local/", AccessToken: "secret-token-123456"})
	if err != nil { t.Fatalf("owner CreateIntegration() error = %v", err) }
	if created.BaseURL != "http://ha.local" { t.Fatalf("normalized base URL = %q", created.BaseURL) }
	if _, err := service.CreateIntegration(context.Background(), member, AddIntegrationRequest{Name: "Nope", BaseURL: "http://ha.local", AccessToken: "secret-token-123456"}); businessCode(t, err) != CodeForbidden { t.Fatalf("member create error = %v", err) }
	name := "Admin update"
	if _, err := service.UpdateIntegration(context.Background(), admin, integration.ID, UpdateIntegrationRequest{Name: &name}); err != nil { t.Fatalf("admin UpdateIntegration() error = %v", err) }
	if err := service.DeleteIntegration(context.Background(), admin, integration.ID); err != nil { t.Fatalf("admin DeleteIntegration() error = %v", err) }
	if _, err := service.UpdateIntegration(context.Background(), Actor{UserID: "other", FamilyID: "family-b", Role: RoleOwner}, integration.ID, UpdateIntegrationRequest{Name: &name}); businessCode(t, err) != CodeNotFound { t.Fatalf("cross-family update error = %v", err) }
	if len(integrations.getFamilies) == 0 || integrations.getFamilies[len(integrations.getFamilies)-1] != "family-b" { t.Fatalf("integration repository did not receive actor family: %#v", integrations.getFamilies) }
}

func TestPermissionManagementAndEntityFiltering(t *testing.T) {
	integration := contractIntegration("family-a", "integration-a")
	visible := contractEntity("family-a", integration.ID, "light.visible")
	hidden := contractEntity("family-a", integration.ID, "light.hidden")
	hidden.IsVisible = false
	notControllable := contractEntity("family-a", integration.ID, "light.readonly")
	notControllable.IsControllable = false
	service, _, entities, permissions, _, _, _ := contractService(integration, visible, contractPermission("family-a", integration.ID, visible.EntityID, RoleMember, CommandTurnOn))
	entities.items[entityKey(integration.ID, hidden.EntityID)] = hidden
	entities.items[entityKey(integration.ID, notControllable.EntityID)] = notControllable
	permissions.items[permissionKey("family-a", integration.ID, hidden.EntityID, RoleMember)] = contractPermission("family-a", integration.ID, hidden.EntityID, RoleMember, CommandTurnOn)
	permissions.items[permissionKey("family-a", integration.ID, notControllable.EntityID, RoleMember)] = contractPermission("family-a", integration.ID, notControllable.EntityID, RoleMember, CommandTurnOn)

	member := Actor{UserID: "member", FamilyID: "family-a", Role: RoleMember}
	values, err := service.ListEntities(context.Background(), member, integration.ID, false)
	if err != nil { t.Fatalf("ListEntities() error = %v", err) }
	if len(values) != 1 || values[0].EntityID != visible.EntityID { t.Fatalf("visible entities = %#v", values) }
	values, err = service.ListEntities(context.Background(), member, integration.ID, true)
	if err != nil { t.Fatalf("ListEntities(controllableOnly) error = %v", err) }
	if len(values) != 1 || values[0].EntityID != visible.EntityID { t.Fatalf("controllable entities = %#v", values) }
	if _, err := service.UpdatePermission(context.Background(), member, PermissionRequest{IntegrationID: integration.ID, EntityID: visible.EntityID, Role: RoleMember, CanView: true}); businessCode(t, err) != CodeForbidden { t.Fatalf("member permission update error = %v", err) }
	if _, err := service.UpdatePermission(context.Background(), Actor{UserID: "owner", FamilyID: "family-a", Role: RoleOwner}, PermissionRequest{IntegrationID: integration.ID, EntityID: visible.EntityID, Role: RoleMember, CanView: true, CanControl: true, AllowedCommands: []Command{CommandTurnOn}}); err != nil { t.Fatalf("owner permission update error = %v", err) }
	if len(permissions.upserts) != 1 { t.Fatalf("permission upserts = %d, want 1", len(permissions.upserts)) }
}

func TestFamilyIsolationUsesIntegrationAndEntityCompositeIdentity(t *testing.T) {
	integrationA := contractIntegration("family-a", "integration-a")
	integrationB := contractIntegration("family-b", "integration-b")
	entityA := contractEntity("family-a", integrationA.ID, "light.same")
	service, integrations, entities, permissions, audit, _, client := contractService(integrationA, entityA)
	integrations.items[integrationB.ID] = integrationB
	entities.items[entityKey(integrationB.ID, entityA.EntityID)] = contractEntity("family-b", integrationB.ID, entityA.EntityID)
	permissions.items[permissionKey("family-b", integrationB.ID, entityA.EntityID, RoleMember)] = contractPermission("family-b", integrationB.ID, entityA.EntityID, RoleMember, CommandTurnOn)

	actor := Actor{UserID: "user-a", FamilyID: "family-a", Role: RoleMember}
	if _, err := service.GetState(context.Background(), actor, integrationB.ID, entityA.EntityID); businessCode(t, err) != CodeNotFound { t.Fatalf("cross-family state error = %v", err) }
	_, err := service.ExecuteCommand(context.Background(), actor, integrationB.ID, entityA.EntityID, CommandRequest{Command: CommandTurnOn, RequestID: contractRequestID})
	if businessCode(t, err) != CodeNotFound { t.Fatalf("cross-family command error = %v", err) }
	if client.executeCalls != 0 { t.Fatalf("cross-family command called HA client %d times", client.executeCalls) }
	if len(integrations.getFamilies) == 0 || integrations.getFamilies[0] != "family-a" { t.Fatalf("integration Get family args = %#v", integrations.getFamilies) }
	if len(entities.getFamilies) < 2 || entities.getFamilies[0] != "family-a" { t.Fatalf("entity Get family args = %#v", entities.getFamilies) }
	if len(audit.logs) != 0 { t.Fatalf("cross-family command should stop before audit after entity isolation, got %#v", audit.logs) }
}

func TestTokenIsEncryptedAndNeverReturnedOrAudited(t *testing.T) {
	integration := contractIntegration("family-a", "integration-a")
	service, integrations, _, _, audit, cipher, client := contractService(integration, contractEntity("family-a", integration.ID, "light.kitchen"), contractPermission("family-a", integration.ID, "light.kitchen", RoleOwner, CommandTurnOn))
	created, err := service.CreateIntegration(context.Background(), Actor{UserID: "owner", FamilyID: "family-a", Role: RoleOwner}, AddIntegrationRequest{Name: "HA", BaseURL: "http://ha.local", AccessToken: "  secret-token-123456  "})
	if err != nil { t.Fatalf("CreateIntegration() error = %v", err) }
	if cipher.encryptInput != "secret-token-123456" { t.Fatalf("Encrypt input = %q", cipher.encryptInput) }
	encoded, _ := json.Marshal(created)
	body := string(encoded)
	for _, forbidden := range []string{"secret-token-123456", "ciphertext", "key_version", "access_token"} {
		if strings.Contains(body, forbidden) { t.Fatalf("integration DTO contains forbidden token material %q: %s", forbidden, body) }
	}
	stored := integrations.items[created.ID]
	stored.Status = IntegrationHealthy
	integrations.items[created.ID] = stored
	entity := contractEntity("family-a", created.ID, "light.kitchen")
	service.Entities.(*contractEntityRepo).items[entityKey(created.ID, entity.EntityID)] = entity
	service.Permissions.(*contractPermissionRepo).items[permissionKey("family-a", created.ID, entity.EntityID, RoleOwner)] = contractPermission("family-a", created.ID, entity.EntityID, RoleOwner, CommandTurnOn)
	_, err = service.ExecuteCommand(context.Background(), Actor{UserID: "owner", FamilyID: "family-a", Role: RoleOwner}, created.ID, entity.EntityID, CommandRequest{Command: CommandTurnOn, RequestID: contractRequestID})
	if err != nil { t.Fatalf("ExecuteCommand() error = %v", err) }
	if string(cipher.decryptInput) != "ciphertext" || cipher.decryptVersion != "v1" || client.lastToken != "secret-token-123456" { t.Fatalf("token flow decrypt=%q version=%q client=%q", cipher.decryptInput, cipher.decryptVersion, client.lastToken) }
	for _, log := range audit.logs {
		encoded, _ := json.Marshal(log)
		if strings.Contains(string(encoded), "secret-token-123456") || strings.Contains(string(encoded), "ciphertext") { t.Fatalf("audit contains token material: %s", encoded) }
	}
}

func TestTypedCommandValidationAndEntityCapabilityGuards(t *testing.T) {
	brightness := 50
	tests := []struct { name string; request CommandRequest; code ErrorCode }{
		{"missing command", CommandRequest{RequestID: contractRequestID}, CodeInvalidCommand},
		{"invalid request id", CommandRequest{Command: CommandTurnOn, RequestID: "not-a-uuid"}, CodeInvalidArgument},
		{"brightness missing", CommandRequest{Command: CommandSetBrightness, RequestID: contractRequestID}, CodeInvalidParameters},
		{"brightness too high", CommandRequest{Command: CommandSetBrightness, RequestID: contractRequestID, Parameters: CommandParameters{Brightness: intPtr(101)}}, CodeInvalidParameters},
		{"temperature missing", CommandRequest{Command: CommandSetTemperature, RequestID: contractRequestID}, CodeInvalidParameters},
		{"temperature out of range", CommandRequest{Command: CommandSetTemperature, RequestID: contractRequestID, Parameters: CommandParameters{Temperature: floatPtr(201)}}, CodeInvalidParameters},
		{"hvac newline", CommandRequest{Command: CommandSetHVACMode, RequestID: contractRequestID, Parameters: CommandParameters{HVACMode: "heat\n"}}, CodeInvalidParameters},
		{"extra on turn_on", CommandRequest{Command: CommandTurnOn, RequestID: contractRequestID, Parameters: CommandParameters{Brightness: &brightness}}, CodeInvalidParameters},
		{"typed params only", CommandRequest{Command: CommandTurnOn, RequestID: contractRequestID, Parameters: CommandParameters{}}, ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := ValidateCommandRequest(test.request)
			if test.code == "" { if err != nil { t.Fatalf("ValidateCommandRequest() error = %v", err) }; return }
			if businessCode(t, err) != test.code { t.Fatalf("error = %v, want %s", err, test.code) }
		})
	}

	entity := contractEntity("family-a", "integration-a", "light.kitchen")
	if !commandAllowedForEntity(entity, CommandSetBrightness, CommandParameters{Brightness: intPtr(50)}) { t.Fatal("brightness command rejected with brightness capability") }
	entity.Capabilities = []string{"on_off"}
	if commandAllowedForEntity(entity, CommandSetBrightness, CommandParameters{Brightness: intPtr(50)}) { t.Fatal("brightness command accepted without brightness capability") }
	entity.Capabilities = []string{"temperature"}; min, max := 18.0, 26.0; entity.TemperatureMin = &min; entity.TemperatureMax = &max
	if commandAllowedForEntity(entity, CommandSetTemperature, CommandParameters{Temperature: floatPtr(30)}) { t.Fatal("temperature above entity maximum accepted") }
	entity.Domain = "climate"; entity.Capabilities = []string{"hvac_mode"}; entity.HVACModes = []string{"heat"}
	if commandAllowedForEntity(entity, CommandSetHVACMode, CommandParameters{HVACMode: "cool"}) { t.Fatal("unsupported HVAC mode accepted") }
	entity.Domain = "scene"
	if !commandAllowedForEntity(entity, CommandActivateScene, CommandParameters{}) { t.Fatal("scene activation rejected for scene entity") }
	entity.Domain = "script"
	if !commandAllowedForEntity(entity, CommandRunScript, CommandParameters{}) { t.Fatal("script execution rejected for script entity") }
}

func intPtr(value int) *int { return &value }
func floatPtr(value float64) *float64 { return &value }

func TestHomeAssistantFailuresMapToExistingUnavailableContractAndAudit(t *testing.T) {
	failures := []struct { name string; err error }{
		{"401", errors.New("ha status 401")},
		{"403", errors.New("ha status 403")},
		{"404", errors.New("ha status 404")},
		{"429", errors.New("ha status 429")},
		{"5xx", errors.New("ha status 503")},
		{"timeout", context.DeadlineExceeded},
	}
	for _, failure := range failures {
		t.Run(failure.name, func(t *testing.T) {
			integration := contractIntegration("family-a", "integration-a")
			entity := contractEntity("family-a", integration.ID, "light.kitchen")
			service, _, _, _, audit, _, client := contractService(integration, entity, contractPermission("family-a", integration.ID, entity.EntityID, RoleMember, CommandTurnOn))
			client.executeErr = failure.err
			_, err := service.ExecuteCommand(context.Background(), Actor{UserID: "member", FamilyID: "family-a", Role: RoleMember}, integration.ID, entity.EntityID, CommandRequest{Command: CommandTurnOn, RequestID: contractRequestID})
			if businessCode(t, err) != CodeIntegrationUnavailable { t.Fatalf("error = %v, want HA_UNAVAILABLE", err) }
			if len(audit.logs) != 1 || audit.logs[0].Result != AuditFailed || audit.logs[0].ErrorCode != string(CodeIntegrationUnavailable) { t.Fatalf("audit = %#v", audit.logs) }
		})
	}
}

func TestRequestIDIsValidatedAndPreservedInAuditForSuccessAndDenied(t *testing.T) {
	integration := contractIntegration("family-a", "integration-a")
	entity := contractEntity("family-a", integration.ID, "light.kitchen")
	service, _, _, permissions, audit, _, client := contractService(integration, entity, contractPermission("family-a", integration.ID, entity.EntityID, RoleMember, CommandTurnOn))
	actor := Actor{UserID: "member", FamilyID: "family-a", Role: RoleMember}
	if _, err := service.ExecuteCommand(context.Background(), actor, integration.ID, entity.EntityID, CommandRequest{Command: CommandTurnOn, RequestID: contractRequestID}); err != nil { t.Fatalf("successful command error = %v", err) }
	permissions.items[permissionKey("family-a", integration.ID, entity.EntityID, RoleMember)] = EntityPermission{FamilyID: "family-a", IntegrationID: integration.ID, EntityID: entity.EntityID, Role: RoleMember, CanView: true, CanControl: false}
	if _, err := service.ExecuteCommand(context.Background(), actor, integration.ID, entity.EntityID, CommandRequest{Command: CommandTurnOn, RequestID: contractRequestID}); businessCode(t, err) != CodeForbidden { t.Fatalf("denied command error = %v", err) }
	if client.executeCalls != 1 { t.Fatalf("denied command called HA client; calls = %d", client.executeCalls) }
	if len(audit.logs) != 2 || audit.logs[0].RequestID != contractRequestID || audit.logs[1].RequestID != contractRequestID || audit.logs[0].Result != AuditSucceeded || audit.logs[1].Result != AuditDenied { t.Fatalf("audit logs = %#v", audit.logs) }
	if !reflect.DeepEqual(audit.logs[0].SafeParametersSummary, map[string]any{}) || audit.logs[0].SafeParametersSummary == nil { t.Fatalf("safe parameter summary = %#v", audit.logs[0].SafeParametersSummary) }
}
