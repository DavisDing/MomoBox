package syncdevice

// RegisterDeviceRequest matches the device registration contract.
type RegisterDeviceRequest struct {
	DeviceID   string   `json:"device_id"`
	DeviceName string   `json:"device_name"`
	Platform   Platform `json:"platform"`
	AppVersion string   `json:"app_version,omitempty"`
}

// TouchCurrentDeviceRequest is deliberately not allowed to carry a device ID
// or client timestamp: the authenticated current device and server clock are
// authoritative.
type TouchCurrentDeviceRequest struct {
	AppVersion string `json:"app_version,omitempty"`
}

// DeviceListResponse matches GET /devices without coupling this package to an
// HTTP handler.
type DeviceListResponse struct {
	Devices []SyncDeviceDTO `json:"devices"`
}
