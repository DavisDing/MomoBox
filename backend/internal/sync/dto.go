package sync

import "time"

// Operation identifies the four write paths supported by the sync protocol.
type Operation string

const (
	OperationEntityUpsert         Operation = "entity_upsert"
	OperationEntityDelete         Operation = "entity_delete"
	OperationInventoryCommand     Operation = "inventory_command"
	OperationHomeAssistantCommand Operation = "home_assistant_command"
)

// PushStatus is intentionally part of the business DTO so an HTTP adapter can
// represent accepted, replayed, conflict and rejected without inferring state
// from which array an item happened to be placed in.
type PushStatus string

const (
	PushStatusAccepted PushStatus = "accepted"
	PushStatusReplayed PushStatus = "replayed"
	PushStatusConflict PushStatus = "conflict"
	PushStatusRejected PushStatus = "rejected"
)

type BootstrapMode string

const (
	BootstrapModeJoinAndMerge    BootstrapMode = "join_and_merge"
	BootstrapModeCreateNewFamily BootstrapMode = "create_new_family"
	BootstrapModeKeepLocalOnly   BootstrapMode = "keep_local_only"
)

// SyncChange is the transport-neutral representation of one client change.
// The command-specific fields are kept top-level because the domain contract
// uses top-level allocations/integration_id while the OpenAPI payload remains
// extensible for future command fields.
type SyncChange struct {
	ChangeID        string                `json:"change_id"`
	Operation       Operation             `json:"operation"`
	Entity          string                `json:"entity,omitempty"`
	EntityID        string                `json:"entity_id,omitempty"`
	BaseVersion     int64                 `json:"base_version,omitempty"`
	Payload         map[string]any        `json:"payload,omitempty"`
	Command         string                `json:"command,omitempty"`
	OperationID     string                `json:"operation_id,omitempty"`
	Allocations     []InventoryAllocation `json:"allocations,omitempty"`
	IntegrationID   string                `json:"integration_id,omitempty"`
	Parameters      map[string]any        `json:"parameters,omitempty"`
	IdempotencyKey  string                `json:"idempotency_key"`
	ClientUpdatedAt string                `json:"client_updated_at,omitempty"`
}

type InventoryAllocation struct {
	BatchID  string `json:"batch_id"`
	Quantity int64  `json:"quantity"`
}

type PushRequest struct {
	DeviceID   string       `json:"device_id"`
	BaseCursor int64        `json:"base_cursor"`
	Changes    []SyncChange `json:"changes"`
}

type PushResponse struct {
	Accepted  []AcceptedChange `json:"accepted"`
	Replayed  []ReplayedChange `json:"replayed"`
	Conflicts []SyncConflict   `json:"conflicts"`
	Rejected  []RejectedChange `json:"rejected"`
	Results   []PushResult     `json:"results"`
	Cursor    int64            `json:"cursor"`
}

type PushResult struct {
	ChangeID       string          `json:"change_id"`
	Status         PushStatus      `json:"status"`
	OriginalStatus PushStatus      `json:"original_status,omitempty"`
	Accepted       *AcceptedChange `json:"accepted,omitempty"`
	Conflict       *SyncConflict   `json:"conflict,omitempty"`
	Rejected       *RejectedChange `json:"rejected,omitempty"`
}

type AcceptedChange struct {
	ChangeID      string         `json:"change_id"`
	EntityID      string         `json:"entity_id,omitempty"`
	ServerVersion int64          `json:"server_version,omitempty"`
	ServerCursor  int64          `json:"server_cursor"`
	Result        map[string]any `json:"result,omitempty"`
	Status        PushStatus     `json:"status,omitempty"`
}

type ReplayedChange struct {
	ChangeID       string          `json:"change_id"`
	OriginalStatus PushStatus      `json:"original_status"`
	Accepted       *AcceptedChange `json:"accepted,omitempty"`
	Conflict       *SyncConflict   `json:"conflict,omitempty"`
	Rejected       *RejectedChange `json:"rejected,omitempty"`
}

type SyncConflict struct {
	ChangeID      string         `json:"change_id"`
	Entity        string         `json:"entity"`
	EntityID      string         `json:"entity_id,omitempty"`
	Reason        string         `json:"reason"`
	ServerVersion int64          `json:"server_version,omitempty"`
	ServerPayload map[string]any `json:"server_payload,omitempty"`
	ClientPayload map[string]any `json:"client_payload,omitempty"`
}

type RejectedChange struct {
	ChangeID string         `json:"change_id"`
	Code     string         `json:"code"`
	Message  string         `json:"message"`
	Details  map[string]any `json:"details,omitempty"`
}

type PullRequest struct {
	DeviceID string `json:"device_id"`
	Cursor   int64  `json:"cursor"`
	Limit    int    `json:"limit,omitempty"`
}

type PullResponse struct {
	Changes    []ChangeLogEntry `json:"changes"`
	NextCursor int64            `json:"next_cursor"`
	HasMore    bool             `json:"has_more"`
}

type ChangeLogEntry struct {
	ChangeID        string         `json:"change_id"`
	Cursor          int64          `json:"cursor"`
	Operation       Operation      `json:"operation"`
	Entity          string         `json:"entity,omitempty"`
	EntityID        string         `json:"entity_id,omitempty"`
	Version         int64          `json:"version,omitempty"`
	Payload         map[string]any `json:"payload,omitempty"`
	Command         string         `json:"command,omitempty"`
	ClientUpdatedAt string         `json:"client_updated_at,omitempty"`
}

type BootstrapRequest struct {
	DeviceID string `json:"device_id"`
}

type BootstrapResponse struct {
	SchemaVersion       int             `json:"schema_version"`
	SyncProtocolVersion int             `json:"sync_protocol_version"`
	ServerCursor        int64           `json:"server_cursor"`
	MergeRequired       bool            `json:"merge_required"`
	AvailableModes      []BootstrapMode `json:"available_modes"`
	Family              map[string]any  `json:"family,omitempty"`
	Snapshot            map[string]any  `json:"snapshot,omitempty"`
}

type BootstrapConfirmRequest struct {
	Mode             BootstrapMode `json:"mode"`
	DeviceID         string        `json:"device_id"`
	LocalWorkspaceID string        `json:"local_workspace_id,omitempty"`
}

type BootstrapConfirmResponse struct {
	Accepted     bool   `json:"accepted"`
	NextAction   string `json:"next_action"`
	ServerCursor int64  `json:"server_cursor"`
}

// DeviceScope is resolved by the repository from an authenticated device id.
// The sync package never trusts a family id supplied by a client payload.
type DeviceScope struct {
	DeviceID string
	FamilyID string
	Revoked  bool
}

type BootstrapSnapshot struct {
	SchemaVersion       int
	SyncProtocolVersion int
	ServerCursor        int64
	MergeRequired       bool
	AvailableModes      []BootstrapMode
	Family              map[string]any
	Snapshot            map[string]any
}

type BootstrapConfirmation struct {
	Accepted     bool
	ServerCursor int64
}

type EntityRecord struct {
	Entity    string
	EntityID  string
	Version   int64
	Payload   map[string]any
	DeletedAt *time.Time
}

type EntityMutation struct {
	Operation       Operation
	Entity          string
	EntityID        string
	BaseVersion     int64
	Payload         map[string]any
	ClientUpdatedAt string
	ChangeID        string
}

type InventoryCommandResult struct {
	EntityID string
	Version  int64
	Payload  map[string]any
}

type HomeAssistantCommandResult struct {
	Payload map[string]any
}

type IdempotencyRecord struct {
	Fingerprint string
	Outcome     StoredOutcome
}

type StoredOutcome struct {
	Status         PushStatus
	OriginalStatus PushStatus
	Accepted       *AcceptedChange
	Conflict       *SyncConflict
	Rejected       *RejectedChange
	ServerCursor   int64
}
