package homeassistant

import "time"

// Role is the role of a user in one family. It is intentionally not inferred
// from a client-provided family_id.
type Role string

const (
	RoleOwner  Role = "owner"
	RoleAdmin  Role = "admin"
	RoleMember Role = "member"
)

func (r Role) Valid() bool                { return r == RoleOwner || r == RoleAdmin || r == RoleMember }
func (r Role) CanManageIntegration() bool { return r == RoleOwner || r == RoleAdmin }
func (r Role) CanManagePermissions() bool { return r == RoleOwner || r == RoleAdmin }

// Actor is the already-authenticated principal supplied by the auth layer.
// The homeassistant package never trusts a family ID in a request DTO.
type Actor struct {
	UserID   string
	FamilyID string
	Role     Role
}

func (a Actor) valid() bool {
	return a.UserID != "" && a.FamilyID != "" && a.Role.Valid()
}

// Integration is the persistence model. TokenCiphertext must only contain an
// encrypted token and must never be copied into an API response.
type Integration struct {
	ID                    string
	FamilyID              string
	Name                  string
	BaseURL               string
	AccessTokenCiphertext []byte
	KeyVersion            string
	Status                IntegrationStatus
	LastCheckedAt         *time.Time
	CreatedAt             time.Time
	UpdatedAt             time.Time
	Enabled               bool
}

type IntegrationStatus string

const (
	IntegrationUnknown            IntegrationStatus = "unknown"
	IntegrationHealthy            IntegrationStatus = "healthy"
	IntegrationUnavailable        IntegrationStatus = "unavailable"
	IntegrationInvalidCredentials IntegrationStatus = "invalid_credentials"
	IntegrationDisabled           IntegrationStatus = "disabled"
)

// HADevice and HAEntity deliberately have separate models and repositories.
// A HA device is not a MomoBox sync device.
type HADevice struct {
	ID            string
	FamilyID      string
	IntegrationID string
	HADeviceID    string
	Name          string
	AreaName      string
	Manufacturer  string
	Model         string
	Enabled       bool
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

type HAEntity struct {
	ID             string
	FamilyID       string
	IntegrationID  string
	DeviceID       string // MomoBox HA device row ID, not sync_devices.id.
	EntityID       string // HA entity_id, e.g. light.kitchen.
	Domain         string
	Name           string
	AreaName       string
	Capabilities   []string
	HVACModes      []string
	TemperatureMin *float64
	TemperatureMax *float64
	CurrentState   string
	IsVisible      bool
	IsControllable bool
	LastStateAt    *time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type EntityPermission struct {
	FamilyID        string
	IntegrationID   string
	EntityID        string
	Role            Role
	CanView         bool
	CanControl      bool
	AllowedCommands []Command
}

type Command string

const (
	CommandTurnOn         Command = "turn_on"
	CommandTurnOff        Command = "turn_off"
	CommandToggle         Command = "toggle"
	CommandSetBrightness  Command = "set_brightness"
	CommandSetTemperature Command = "set_temperature"
	CommandSetHVACMode    Command = "set_hvac_mode"
	CommandPlay           Command = "play"
	CommandPause          Command = "pause"
	CommandActivateScene  Command = "activate_scene"
	CommandRunScript      Command = "run_script"
)

var allowedCommands = map[Command]struct{}{
	CommandTurnOn: {}, CommandTurnOff: {}, CommandToggle: {},
	CommandSetBrightness: {}, CommandSetTemperature: {},
	CommandSetHVACMode: {}, CommandPlay: {}, CommandPause: {},
	CommandActivateScene: {}, CommandRunScript: {},
}

func (c Command) Valid() bool {
	_, ok := allowedCommands[c]
	return ok
}

// CommandParameters is the only parameter shape accepted by the service. It
// does not contain domain/service/service_data, and therefore cannot be used
// to tunnel arbitrary Home Assistant calls.
type CommandParameters struct {
	Brightness  *int
	Temperature *float64
	HVACMode    string
}

type CommandRequest struct {
	Command    Command
	Parameters CommandParameters
	RequestID  string
}

type CommandInvocation struct {
	EntityID   string
	Domain     string
	Command    Command
	Parameters CommandParameters
}

type HAState struct {
	EntityID   string
	State      string
	Attributes map[string]any
	FetchedAt  time.Time
}

type ConnectionResult struct {
	Connected     bool
	ServerVersion string
	ErrorCode     string
}

type Discovery struct {
	Devices  []DiscoveredDevice
	Entities []DiscoveredEntity
}

type DiscoveredDevice struct {
	HADeviceID   string
	Name         string
	AreaName     string
	Manufacturer string
	Model        string
}

type DiscoveredEntity struct {
	EntityID       string
	HADeviceID     string
	Domain         string
	Name           string
	AreaName       string
	Capabilities   []string
	HVACModes      []string
	TemperatureMin *float64
	TemperatureMax *float64
	CurrentState   string
}

type CommandResult struct {
	Accepted bool
	State    *HAState
}

type AuditResult string

const (
	AuditSucceeded AuditResult = "succeeded"
	AuditFailed    AuditResult = "failed"
	AuditDenied    AuditResult = "denied"
)

type CommandAuditLog struct {
	FamilyID              string
	IntegrationID         string
	EntityID              string
	RequestedBy           string
	Command               Command
	SafeParametersSummary map[string]any
	Result                AuditResult
	ErrorCode             string
	CreatedAt             time.Time
	RequestID             string
}
