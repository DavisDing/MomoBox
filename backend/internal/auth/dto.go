package auth

import "time"

type RegisterDeviceRequest struct {
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
	AppVersion string `json:"app_version,omitempty"`
}

type RegisterRequest struct {
	Email    string                 `json:"email"`
	Password string                 `json:"password"`
	Nickname string                 `json:"nickname"`
	Device   *RegisterDeviceRequest `json:"device,omitempty"`
}

type LoginRequest struct {
	Email    string                 `json:"email"`
	Password string                 `json:"password"`
	Device   *RegisterDeviceRequest `json:"device,omitempty"`
}

type RefreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

type AuthResponse struct {
	User         User   `json:"user"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
}

type MeResponse struct {
	User     User               `json:"user"`
	Families []FamilyMembership `json:"families"`
	Devices  []SyncDevice       `json:"devices"`
}

type AccessTokenResponse struct {
	Claims Principal
}

// DeviceRecord is the minimal repository input needed by authentication.
type DeviceRecord struct {
	ID         string
	UserID     string
	FamilyID   string
	DeviceName string
	Platform   string
	AppVersion string
	CreatedAt  time.Time
	LastSeenAt *time.Time
	RevokedAt  *time.Time
}
