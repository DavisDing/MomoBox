package homeassistant_test

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	ha "github.com/momobox/backend/internal/homeassistant"
)

type fakeIntegrations struct {
	item    ha.Integration
	updated int
}

func (f *fakeIntegrations) Create(_ context.Context, item ha.Integration) error {
	f.item = item
	return nil
}
func (f *fakeIntegrations) Get(_ context.Context, familyID, integrationID string) (ha.Integration, error) {
	if f.item.FamilyID != familyID || f.item.ID != integrationID {
		return ha.Integration{}, &ha.BusinessError{Code: ha.CodeNotFound, Message: "not found"}
	}
	return f.item, nil
}
func (f *fakeIntegrations) List(_ context.Context, familyID string) ([]ha.Integration, error) {
	if f.item.FamilyID != familyID {
		return nil, nil
	}
	return []ha.Integration{f.item}, nil
}
func (f *fakeIntegrations) Update(_ context.Context, familyID string, item ha.Integration) error {
	if familyID != f.item.FamilyID {
		return errors.New("wrong family")
	}
	f.item = item
	f.updated++
	return nil
}
func (f *fakeIntegrations) Delete(_ context.Context, familyID, integrationID string) error {
	if familyID != f.item.FamilyID || integrationID != f.item.ID {
		return errors.New("wrong resource")
	}
	f.item = ha.Integration{}
	return nil
}

type fakeDevices struct{}

func (fakeDevices) ReplaceForIntegration(context.Context, string, string, []ha.HADevice) error {
	return nil
}
func (fakeDevices) List(context.Context, string, string) ([]ha.HADevice, error) { return nil, nil }

type fakeEntities struct {
	item     ha.HAEntity
	items    []ha.HAEntity
	replaced []ha.HAEntity
}

func (f *fakeEntities) ReplaceForIntegration(_ context.Context, familyID, integrationID string, items []ha.HAEntity) error {
	f.replaced = items
	return nil
}
func (f *fakeEntities) Get(_ context.Context, familyID, integrationID, entityID string) (ha.HAEntity, error) {
	items := f.items
	if len(items) == 0 {
		items = []ha.HAEntity{f.item}
	}
	for _, item := range items {
		if item.FamilyID == familyID && item.IntegrationID == integrationID && item.EntityID == entityID {
			return item, nil
		}
	}
	return ha.HAEntity{}, &ha.BusinessError{Code: ha.CodeNotFound, Message: "not found"}
}
func (f *fakeEntities) List(_ context.Context, familyID, integrationID string) ([]ha.HAEntity, error) {
	items := f.items
	if len(items) == 0 {
		items = []ha.HAEntity{f.item}
	}
	result := make([]ha.HAEntity, 0, len(items))
	for _, item := range items {
		if item.FamilyID == familyID && (integrationID == "" || item.IntegrationID == integrationID) {
			result = append(result, item)
		}
	}
	return result, nil
}

type fakePermissions struct {
	byRole   map[ha.Role]ha.EntityPermission
	upserted *ha.EntityPermission
}

func (f *fakePermissions) Get(_ context.Context, familyID, integrationID, entityID string, role ha.Role) (ha.EntityPermission, error) {
	p, ok := f.byRole[role]
	if !ok || p.FamilyID != familyID || p.IntegrationID != integrationID || p.EntityID != entityID {
		return ha.EntityPermission{}, &ha.BusinessError{Code: ha.CodeNotFound, Message: "not found"}
	}
	return p, nil
}
func (f *fakePermissions) List(context.Context, string) ([]ha.EntityPermission, error) {
	return nil, nil
}
func (f *fakePermissions) Upsert(_ context.Context, p ha.EntityPermission) error {
	f.upserted = &p
	return nil
}

type fakeCipher struct {
	encrypted     string
	seenPlaintext string
}

func (f *fakeCipher) Encrypt(_ context.Context, plaintext string) ([]byte, string, error) {
	f.seenPlaintext = plaintext
	return []byte("ciphertext"), "v1", nil
}
func (f *fakeCipher) Decrypt(_ context.Context, ciphertext []byte, keyVersion string) (string, error) {
	if string(ciphertext) != "ciphertext" || keyVersion != "v1" {
		return "", errors.New("bad ciphertext")
	}
	return f.encrypted, nil
}

type fakeClient struct {
	executeCalls int
	invocation   ha.CommandInvocation
	stateCalls   int
	stateEntity  ha.HAEntity
	discovery    ha.Discovery
}

func (f *fakeClient) Test(context.Context, string, string) (ha.ConnectionResult, error) {
	return ha.ConnectionResult{Connected: true, ServerVersion: "2026.9"}, nil
}
func (f *fakeClient) Discover(context.Context, string, string) (ha.Discovery, error) {
	return f.discovery, nil
}
func (f *fakeClient) GetState(_ context.Context, _ string, _ string, entity ha.HAEntity) (ha.HAState, error) {
	f.stateCalls++
	f.stateEntity = entity
	return ha.HAState{EntityID: entity.EntityID, State: entity.CurrentState}, nil
}
func (f *fakeClient) Execute(_ context.Context, _ string, _ string, invocation ha.CommandInvocation) (ha.CommandResult, error) {
	f.executeCalls++
	f.invocation = invocation
	return ha.CommandResult{Accepted: true}, nil
}

type fakeAudit struct{ logs []ha.CommandAuditLog }

func (f *fakeAudit) Append(_ context.Context, log ha.CommandAuditLog) error {
	f.logs = append(f.logs, log)
	return nil
}

func testService(rolePermissions map[ha.Role]ha.EntityPermission) (*ha.Service, *fakeClient, *fakeAudit) {
	integrations := &fakeIntegrations{item: ha.Integration{ID: "integration-1", FamilyID: "family-a", Name: "Home", BaseURL: "http://ha.local:8123", AccessTokenCiphertext: []byte("ciphertext"), KeyVersion: "v1", Enabled: true}}
	entities := &fakeEntities{item: ha.HAEntity{ID: "row-1", FamilyID: "family-a", IntegrationID: "integration-1", EntityID: "light.kitchen", Domain: "light", Name: "Kitchen", Capabilities: []string{"on_off", "brightness"}, IsVisible: true, IsControllable: true}}
	permissions := &fakePermissions{byRole: rolePermissions}
	cipher := &fakeCipher{encrypted: "long-lived-secret-token"}
	client := &fakeClient{}
	audit := &fakeAudit{}
	return &ha.Service{Integrations: integrations, Devices: fakeDevices{}, Entities: entities, Permissions: permissions, Audit: audit, Cipher: cipher, Client: client, Now: func() time.Time { return time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC) }}, client, audit
}

func actor(role ha.Role) ha.Actor {
	return ha.Actor{UserID: "user-1", FamilyID: "family-a", Role: role}
}
func permission(role ha.Role, canControl bool, commands ...ha.Command) ha.EntityPermission {
	return ha.EntityPermission{FamilyID: "family-a", IntegrationID: "integration-1", EntityID: "light.kitchen", Role: role, CanView: true, CanControl: canControl, AllowedCommands: commands}
}

func TestCommandSurfaceIsTypedAndAllowlisted(t *testing.T) {
	typ := reflect.TypeOf(ha.CommandParameters{})
	for _, forbidden := range []string{"Domain", "Service", "ServiceData"} {
		if _, ok := typ.FieldByName(forbidden); ok {
			t.Fatalf("CommandParameters exposes forbidden raw HA field %q", forbidden)
		}
	}
	for _, allowed := range []ha.Command{
		ha.CommandTurnOn, ha.CommandTurnOff, ha.CommandToggle,
		ha.CommandSetBrightness, ha.CommandSetTemperature, ha.CommandSetHVACMode,
		ha.CommandPlay, ha.CommandPause, ha.CommandActivateScene, ha.CommandRunScript,
	} {
		if !ha.IsAllowedCommand(allowed) {
			t.Fatalf("allowlisted command %q was rejected", allowed)
		}
	}
	if ha.IsAllowedCommand(ha.Command("call_service")) {
		t.Fatal("arbitrary HA command was accepted")
	}
}

func TestValidateBaseURLAndToken(t *testing.T) {
	for _, value := range []string{"", "ftp://ha.local", "http://user:pass@ha.local", "http://ha.local/path", "http://ha.local?token=x", "http://ha.local#fragment"} {
		if err := ha.ValidateBaseURL(value); err == nil {
			t.Fatalf("ValidateBaseURL(%q) accepted an unsafe URL", value)
		}
	}
	for _, token := range []string{"", "short", "0123456789012345\nsecret"} {
		if err := ha.ValidateAccessToken(token); err == nil {
			t.Fatalf("ValidateAccessToken(%q) accepted an invalid token", token)
		}
	}
	if err := ha.ValidateBaseURL("https://ha.local:8123/"); err != nil {
		t.Fatalf("valid URL rejected: %v", err)
	}
}

func TestDiscoveryKeepsDeviceLessScenesAndScripts(t *testing.T) {
	integrations := &fakeIntegrations{item: ha.Integration{ID: "integration-1", FamilyID: "family-a", Name: "Home", BaseURL: "http://ha.local:8123", AccessTokenCiphertext: []byte("ciphertext"), KeyVersion: "v1", Enabled: true}}
	devices := fakeDevices{}
	entities := &fakeEntities{}
	client := &fakeClient{discovery: ha.Discovery{
		Devices: []ha.DiscoveredDevice{{HADeviceID: "device-1", Name: "Lamp"}},
		Entities: []ha.DiscoveredEntity{
			{EntityID: "scene.movie", Domain: "scene"},
			{EntityID: "script.goodnight", Domain: "script"},
			{EntityID: "light.lamp", HADeviceID: "device-1", Domain: "light", Capabilities: []string{"on_off"}},
			{EntityID: "light.orphan", HADeviceID: "unknown-device", Domain: "light", Capabilities: []string{"on_off"}},
		},
	}}
	service := &ha.Service{
		Integrations: integrations, Devices: devices, Entities: entities,
		Cipher: &fakeCipher{encrypted: "long-lived-secret-token"}, Client: client,
	}
	got, err := service.Discover(context.Background(), actor(ha.RoleOwner), "integration-1")
	if err != nil {
		t.Fatalf("Discover() error = %v", err)
	}
	if got.Devices != 1 || got.Entities != 3 {
		t.Fatalf("unexpected discovery counts: %#v", got)
	}
	if len(entities.replaced) != 3 {
		t.Fatalf("unexpected cached entities: %#v", entities.replaced)
	}
	for _, entity := range entities.replaced {
		if entity.EntityID == "scene.movie" || entity.EntityID == "script.goodnight" {
			if entity.DeviceID != "" || !entity.IsControllable {
				t.Fatalf("device-less scene/script was not preserved as controllable entity: %#v", entity)
			}
		}
	}
}

func TestCreateIntegrationEncryptsTokenAndNeverReturnsIt(t *testing.T) {
	service, _, _ := testService(nil)
	got, err := service.CreateIntegration(context.Background(), actor(ha.RoleOwner), ha.AddIntegrationRequest{Name: "Home", BaseURL: "http://ha.local:8123", AccessToken: "long-lived-secret-token"})
	if err != nil {
		t.Fatalf("CreateIntegration() error = %v", err)
	}
	if got.BaseURL != "http://ha.local:8123" || got.ID == "" {
		t.Fatalf("unexpected DTO: %#v", got)
	}
	if got.Name == "long-lived-secret-token" || got.BaseURL == "long-lived-secret-token" {
		t.Fatal("token was returned in the integration DTO")
	}
}

func TestMemberCannotUseOwnerPermissionOrControl(t *testing.T) {
	service, client, audit := testService(map[ha.Role]ha.EntityPermission{
		ha.RoleOwner: permission(ha.RoleOwner, true, ha.CommandTurnOn),
	})
	_, err := service.ExecuteCommand(context.Background(), actor(ha.RoleMember), "integration-1", "light.kitchen", ha.CommandRequest{Command: ha.CommandTurnOn, RequestID: "123e4567-e89b-12d3-a456-426614174000"})
	if err == nil {
		t.Fatal("member used a permission belonging to owner")
	}
	business, ok := err.(*ha.BusinessError)
	if !ok || business.Code != ha.CodeNotFound {
		t.Fatalf("unexpected error: %#v", err)
	}
	if client.executeCalls != 0 || len(audit.logs) != 1 || audit.logs[0].Result != ha.AuditDenied {
		t.Fatal("unauthorized member reached HA or was not audited")
	}
}

func TestCommandRejectsArbitraryServiceDataAndUnsupportedCapabilities(t *testing.T) {
	service, client, _ := testService(map[ha.Role]ha.EntityPermission{ha.RoleMember: permission(ha.RoleMember, true, ha.CommandTurnOn, ha.CommandSetBrightness, ha.CommandSetTemperature)})
	_, err := service.ExecuteCommand(context.Background(), actor(ha.RoleMember), "integration-1", "light.kitchen", ha.CommandRequest{Command: ha.CommandTurnOn, Parameters: ha.CommandParameters{Brightness: intPtr(1)}, RequestID: "123e4567-e89b-12d3-a456-426614174000"})
	if err == nil {
		t.Fatal("turn_on accepted parameters that could tunnel service_data")
	}
	if client.executeCalls != 0 {
		t.Fatal("invalid command reached the HA client")
	}

	_, err = service.ExecuteCommand(context.Background(), actor(ha.RoleMember), "integration-1", "light.kitchen", ha.CommandRequest{Command: ha.CommandSetTemperature, Parameters: ha.CommandParameters{Temperature: floatPtr(22)}, RequestID: "123e4567-e89b-12d3-a456-426614174001"})
	if err == nil {
		t.Fatal("set_temperature accepted for an entity without temperature capability")
	}
	if business, ok := err.(*ha.BusinessError); !ok || business.Code != ha.CodeUnsupportedCommand {
		t.Fatalf("unexpected unsupported-capability error: %#v", err)
	}
	if client.executeCalls != 0 {
		t.Fatal("unsupported command reached the HA client")
	}
}

func TestValidCommandUsesTypedWhitelistAndAuditsSafeParameters(t *testing.T) {
	service, client, audit := testService(map[ha.Role]ha.EntityPermission{ha.RoleMember: permission(ha.RoleMember, true, ha.CommandSetBrightness)})
	brightness := 80
	got, err := service.ExecuteCommand(context.Background(), actor(ha.RoleMember), "integration-1", "light.kitchen", ha.CommandRequest{Command: ha.CommandSetBrightness, Parameters: ha.CommandParameters{Brightness: &brightness}, RequestID: "123e4567-e89b-12d3-a456-426614174000"})
	if err != nil {
		t.Fatalf("ExecuteCommand() error = %v", err)
	}
	if !got.Accepted || client.executeCalls != 1 {
		t.Fatalf("unexpected command response: %#v", got)
	}
	if client.invocation.Domain != "light" || client.invocation.EntityID != "light.kitchen" || client.invocation.Command != ha.CommandSetBrightness {
		t.Fatalf("client got unsafe or incorrect invocation: %#v", client.invocation)
	}
	if len(audit.logs) != 1 || audit.logs[0].Result != ha.AuditSucceeded || audit.logs[0].SafeParametersSummary["brightness"] != 80 {
		t.Fatalf("audit log missing safe summary: %#v", audit.logs)
	}
	if _, leaked := audit.logs[0].SafeParametersSummary["service_data"]; leaked {
		t.Fatal("audit contains raw service_data")
	}
}

func TestCommandSelectsEntityByIntegrationAndEntityID(t *testing.T) {
	service, client, audit := testService(map[ha.Role]ha.EntityPermission{ha.RoleMember: permission(ha.RoleMember, true, ha.CommandTurnOn)})
	entities := service.Entities.(*fakeEntities)
	entities.items = []ha.HAEntity{
		{ID: "row-other", FamilyID: "family-a", IntegrationID: "integration-2", EntityID: "light.kitchen", Domain: "switch", Capabilities: []string{"on_off"}, IsVisible: true, IsControllable: true},
		entities.item,
	}

	_, err := service.ExecuteCommand(context.Background(), actor(ha.RoleMember), "integration-1", "light.kitchen", ha.CommandRequest{Command: ha.CommandTurnOn, RequestID: "123e4567-e89b-12d3-a456-426614174002"})
	if err != nil {
		t.Fatalf("ExecuteCommand() error = %v", err)
	}
	if client.invocation.Domain != "light" {
		t.Fatalf("selected entity domain = %q, want integration-1 light", client.invocation.Domain)
	}
	if len(audit.logs) != 1 || audit.logs[0].IntegrationID != "integration-1" {
		t.Fatalf("audit did not preserve integration identity: %#v", audit.logs)
	}
}

func TestStateSelectsEntityByIntegrationAndEntityID(t *testing.T) {
	service, client, _ := testService(map[ha.Role]ha.EntityPermission{ha.RoleMember: permission(ha.RoleMember, false)})
	entities := service.Entities.(*fakeEntities)
	entities.items = []ha.HAEntity{
		{ID: "row-other", FamilyID: "family-a", IntegrationID: "integration-2", EntityID: "light.kitchen", Domain: "switch", CurrentState: "off", IsVisible: true},
		entities.item,
	}

	_, err := service.GetState(context.Background(), actor(ha.RoleMember), "integration-1", "light.kitchen")
	if err != nil {
		t.Fatalf("GetState() error = %v", err)
	}
	if client.stateCalls != 1 || client.stateEntity.IntegrationID != "integration-1" || client.stateEntity.Domain != "light" {
		t.Fatalf("state lookup selected wrong entity: %#v", client.stateEntity)
	}
}

func TestPermissionUpdateSelectsEntityByIntegrationAndReturnsIntegrationID(t *testing.T) {
	service, _, _ := testService(nil)
	entities := service.Entities.(*fakeEntities)
	entities.items = []ha.HAEntity{
		entities.item,
		{ID: "row-2", FamilyID: "family-a", IntegrationID: "integration-2", EntityID: "light.kitchen", Domain: "light", IsVisible: true, IsControllable: true},
	}
	permissions := service.Permissions.(*fakePermissions)

	got, err := service.UpdatePermission(context.Background(), actor(ha.RoleOwner), ha.PermissionRequest{IntegrationID: "integration-2", EntityID: "light.kitchen", Role: ha.RoleMember, CanView: true, CanControl: true, AllowedCommands: []ha.Command{ha.CommandTurnOn}})
	if err != nil {
		t.Fatalf("UpdatePermission() error = %v", err)
	}
	if got.IntegrationID != "integration-2" || permissions.upserted == nil || permissions.upserted.IntegrationID != "integration-2" {
		t.Fatalf("permission lost integration identity: dto=%#v upsert=%#v", got, permissions.upserted)
	}
}

func TestMemberCannotChangeHAPermissions(t *testing.T) {
	service, _, _ := testService(nil)
	_, err := service.UpdatePermission(context.Background(), actor(ha.RoleMember), ha.PermissionRequest{IntegrationID: "integration-1", EntityID: "light.kitchen", Role: ha.RoleOwner, CanView: true, CanControl: true, AllowedCommands: []ha.Command{ha.CommandTurnOn}})
	if err == nil {
		t.Fatal("member changed HA permissions")
	}
	if business, ok := err.(*ha.BusinessError); !ok || business.Code != ha.CodeForbidden {
		t.Fatalf("unexpected error: %#v", err)
	}
}

func intPtr(value int) *int           { return &value }
func floatPtr(value float64) *float64 { return &value }
