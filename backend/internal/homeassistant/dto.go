package homeassistant

import "time"

// These DTOs match the HA portion of docs/nas/02-api-contract.yaml. They are
// deliberately separate from persistence models so encrypted tokens cannot be
// returned accidentally.
type AddIntegrationRequest struct {
	Name        string
	BaseURL     string
	AccessToken string
}

type UpdateIntegrationRequest struct {
	Name        *string
	BaseURL     *string
	AccessToken *string
	Enabled     *bool
}

type IntegrationDTO struct {
	ID            string
	Name          string
	BaseURL       string
	Status        IntegrationStatus
	LastCheckedAt *time.Time
	CreatedAt     time.Time
	UpdatedAt     time.Time
	Enabled       bool
}

type ConnectionTestDTO struct {
	Connected     bool
	CheckedAt     time.Time
	ServerVersion string
	ErrorCode     string
}

type DiscoveryDTO struct {
	IntegrationID string
	Devices       int
	Entities      int
}

type DeviceDTO struct {
	ID            string
	IntegrationID string
	HADeviceID    string
	Name          string
	AreaName      string
	Manufacturer  string
	Model         string
}

type EntityDTO struct {
	ID             string
	IntegrationID  string
	DeviceID       string
	EntityID       string
	Domain         string
	Name           string
	AreaName       string
	Capabilities   []string
	HVACModes      []string
	TemperatureMin *float64
	TemperatureMax *float64
	CurrentState   *string
	IsVisible      bool
	IsControllable bool
	LastStateAt    *time.Time
}

type StateDTO struct {
	EntityID   string
	State      string
	Attributes map[string]any
	FetchedAt  time.Time
}

type CommandDTO struct {
	Accepted   bool
	EntityID   string
	Command    Command
	ExecutedAt time.Time
	State      *StateDTO
}

type PermissionRequest struct {
	IntegrationID   string
	EntityID        string
	Role            Role
	CanView         bool
	CanControl      bool
	AllowedCommands []Command
}

type PermissionDTO struct {
	IntegrationID   string
	EntityID        string
	Role            Role
	CanView         bool
	CanControl      bool
	AllowedCommands []Command
}

func integrationDTO(i Integration) IntegrationDTO {
	return IntegrationDTO{
		ID: i.ID, Name: i.Name, BaseURL: i.BaseURL, Status: i.Status,
		LastCheckedAt: cloneTime(i.LastCheckedAt), CreatedAt: i.CreatedAt,
		UpdatedAt: i.UpdatedAt, Enabled: i.Enabled,
	}
}

func deviceDTO(d HADevice) DeviceDTO {
	return DeviceDTO{ID: d.ID, IntegrationID: d.IntegrationID, HADeviceID: d.HADeviceID,
		Name: d.Name, AreaName: d.AreaName, Manufacturer: d.Manufacturer, Model: d.Model}
}

func entityDTO(e HAEntity) EntityDTO {
	var state *string
	if e.CurrentState != "" {
		value := e.CurrentState
		state = &value
	}
	return EntityDTO{ID: e.ID, IntegrationID: e.IntegrationID, DeviceID: e.DeviceID,
		EntityID: e.EntityID, Domain: e.Domain, Name: e.Name, AreaName: e.AreaName,
		Capabilities: append([]string(nil), e.Capabilities...), HVACModes: append([]string(nil), e.HVACModes...), TemperatureMin: cloneFloat(e.TemperatureMin), TemperatureMax: cloneFloat(e.TemperatureMax), CurrentState: state,
		IsVisible: e.IsVisible, IsControllable: e.IsControllable,
		LastStateAt: cloneTime(e.LastStateAt)}
}

func stateDTO(s *HAState) *StateDTO {
	if s == nil {
		return nil
	}
	attributes := make(map[string]any, len(s.Attributes))
	for k, v := range s.Attributes {
		attributes[k] = v
	}
	return &StateDTO{EntityID: s.EntityID, State: s.State, Attributes: attributes, FetchedAt: s.FetchedAt}
}

func cloneFloat(value *float64) *float64 {
	if value == nil {
		return nil
	}
	v := *value
	return &v
}

func cloneTime(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	v := *t
	return &v
}
