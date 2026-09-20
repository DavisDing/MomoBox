package homeassistant

import "context"

// Every repository method takes familyID. Resource IDs alone are never an
// authorization boundary.
type IntegrationRepository interface {
	Create(ctx context.Context, integration Integration) error
	Get(ctx context.Context, familyID, integrationID string) (Integration, error)
	List(ctx context.Context, familyID string) ([]Integration, error)
	Update(ctx context.Context, familyID string, integration Integration) error
	Delete(ctx context.Context, familyID, integrationID string) error
}

type DeviceRepository interface {
	ReplaceForIntegration(ctx context.Context, familyID, integrationID string, devices []HADevice) error
	List(ctx context.Context, familyID, integrationID string) ([]HADevice, error)
}

type EntityRepository interface {
	ReplaceForIntegration(ctx context.Context, familyID, integrationID string, entities []HAEntity) error
	Get(ctx context.Context, familyID, integrationID, entityID string) (HAEntity, error)
	List(ctx context.Context, familyID, integrationID string) ([]HAEntity, error)
}

type PermissionRepository interface {
	Get(ctx context.Context, familyID, integrationID, entityID string, role Role) (EntityPermission, error)
	List(ctx context.Context, familyID string) ([]EntityPermission, error)
	Upsert(ctx context.Context, permission EntityPermission) error
}

type AuditRepository interface {
	Append(ctx context.Context, log CommandAuditLog) error
}

// TokenCipher is the deployment-provided encryption boundary. Implementations
// should use HA_TOKEN_ENCRYPTION_KEY and return a key version for rotation.
type TokenCipher interface {
	Encrypt(ctx context.Context, plaintext string) (ciphertext []byte, keyVersion string, err error)
	Decrypt(ctx context.Context, ciphertext []byte, keyVersion string) (plaintext string, err error)
}

// Client is an adapter contract only. This package never performs an HTTP call
// and intentionally receives typed invocations instead of raw HA service data.
type HAClient interface {
	Test(ctx context.Context, baseURL, accessToken string) (ConnectionResult, error)
	Discover(ctx context.Context, baseURL, accessToken string) (Discovery, error)
	GetState(ctx context.Context, baseURL, accessToken string, entity HAEntity) (HAState, error)
	Execute(ctx context.Context, baseURL, accessToken string, invocation CommandInvocation) (CommandResult, error)
}

// Client is retained as a concise alias for adapters that prefer the generic
// name while HAClient documents the boundary explicitly.
type Client = HAClient
