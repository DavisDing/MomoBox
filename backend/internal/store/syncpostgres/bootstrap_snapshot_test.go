package syncpostgres

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"
	"sync"
	"testing"

	syncdomain "github.com/momobox/backend/internal/sync"
)

// This driver checks database/sql transaction ownership, not PostgreSQL MVCC,
// trigger timing, cursor commit ordering, or real concurrent writer behavior.
// It deliberately rejects reads made outside the single snapshot transaction.
type bootstrapSnapshotDriverState struct {
	mu sync.Mutex
	familyID string
	deviceID string
	checkpoint string
	savedCheckpoint string
	savedCursor int64
	checkpointState string
	emptyCheckpoint bool
	emptyDevice bool
	checkpointWrites int
	checkpointArgs []driver.NamedValue
	executions []string
	beginErr error
	commitErr error
	failAt string
	queryErr error
	invalidJSONAt string
	emptyFamily bool
	cursorValue driver.Value
	begins int
	commits int
	rollbacks int
	outsideReads int
	active bool
	options driver.TxOptions
	queries []string
}

type bootstrapSnapshotConnector struct { state *bootstrapSnapshotDriverState }
type bootstrapSnapshotDriver struct{}
type bootstrapSnapshotCheckpoint struct {
	checkpoint string
	cursor int64
	state string
}
type bootstrapSnapshotConn struct {
	state *bootstrapSnapshotDriverState
	inTx bool
	pendingCheckpoint *bootstrapSnapshotCheckpoint
}
type bootstrapSnapshotTx struct { state *bootstrapSnapshotDriverState; conn *bootstrapSnapshotConn }
type bootstrapSnapshotRows struct { values []driver.Value; done bool }

var _ driver.Connector = (*bootstrapSnapshotConnector)(nil)
var _ driver.ConnBeginTx = (*bootstrapSnapshotConn)(nil)
var _ driver.QueryerContext = (*bootstrapSnapshotConn)(nil)
var _ driver.ExecerContext = (*bootstrapSnapshotConn)(nil)

func (c *bootstrapSnapshotConnector) Connect(context.Context) (driver.Conn, error) {
	return &bootstrapSnapshotConn{state: c.state}, nil
}
func (c *bootstrapSnapshotConnector) Driver() driver.Driver { return bootstrapSnapshotDriver{} }
func (bootstrapSnapshotDriver) Open(string) (driver.Conn, error) {
	return nil, errors.New("bootstrap snapshot test requires OpenDB connector")
}
func (c *bootstrapSnapshotConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepared statement during bootstrap")
}
func (c *bootstrapSnapshotConn) Close() error { return nil }
func (c *bootstrapSnapshotConn) Begin() (driver.Tx, error) {
	return nil, errors.New("bootstrap must use BeginTx with explicit options")
}
func (c *bootstrapSnapshotConn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	if err := ctx.Err(); err != nil { return nil, err }
	s := c.state
	s.mu.Lock()
	defer s.mu.Unlock()
	s.begins++
	s.options = opts
	if s.beginErr != nil { return nil, s.beginErr }
	if s.active { return nil, errors.New("nested snapshot transaction") }
	s.active = true
	c.inTx = true
	c.pendingCheckpoint = nil
	return &bootstrapSnapshotTx{state: s, conn: c}, nil
}
func (c *bootstrapSnapshotConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if err := ctx.Err(); err != nil { return nil, err }
	s := c.state
	s.mu.Lock()
	defer s.mu.Unlock()
	if !c.inTx {
		s.outsideReads++
		return nil, errors.New("bootstrap read escaped transaction")
	}
	label := ""
	switch {
	case strings.Contains(query, "FROM sync_devices"):
		label = "device"
		if !strings.Contains(query, "FOR UPDATE") || !strings.Contains(query, "revoked_at IS NULL") || !strings.Contains(query, "deleted_at IS NULL") || len(args) != 2 || args[0].Value != s.deviceID || args[1].Value != s.familyID {
			return nil, errors.New("bootstrap device lock lost scope or revocation guard")
		}
	case strings.Contains(query, "SELECT checkpoint::text, snapshot_cursor FROM sync_bootstrap_checkpoints"),
		strings.Contains(query, "SELECT state, checkpoint::text, snapshot_cursor FROM sync_bootstrap_checkpoints"):
		label = "saved_checkpoint"
		if !strings.Contains(query, "FOR UPDATE") || len(args) != 2 || args[0].Value != s.familyID || args[1].Value != s.deviceID {
			return nil, errors.New("checkpoint validation lost transaction scope")
		}
	case strings.Contains(query, "INSERT INTO sync_bootstrap_checkpoints"):
		label = "checkpoint"
		if s.options.ReadOnly || len(args) < 3 || args[0].Value != s.familyID || args[1].Value != s.deviceID {
			return nil, errors.New("checkpoint write lost scope or used read-only transaction")
		}
		if len(args) == 3 {
			if args[2].Value != s.cursorValue {
				return nil, errors.New("checkpoint cursor differs from snapshot cursor")
			}
			// The fake models returned values, so also guard the SQL contract.
			if !strings.Contains(query, "checkpoint = gen_random_uuid()") || !strings.Contains(query, "state = 'pending'") || !strings.Contains(query, "confirmed_at = NULL") || strings.Contains(query, "mode =") || strings.Contains(query, "local_workspace_id =") {
				return nil, errors.New("snapshot refresh must invalidate confirmation and preserve the chosen mode/workspace")
			}
		} else if len(args) != 6 {
			return nil, errors.New("unexpected confirmation checkpoint arguments")
		} else if args[3].Value == string(syncdomain.BootstrapModeKeepLocalOnly) && (args[4].Value != int64(0) || args[5].Value != nil) {
			return nil, errors.New("keep-local client cursor or checkpoint reached SQL")
		} else if args[5].Value != nil {
			token, ok := args[5].Value.(string)
			if !ok || !isUUID(token) {
				return nil, errors.New("invalid checkpoint reached SQL UUID cast")
			}
		}
	case strings.Contains(query, "FROM families"):
		label = "family"
		if !strings.Contains(query, "deleted_at IS NULL") {
			return nil, errors.New("bootstrap family must exclude deleted families")
		}
	case strings.TrimSpace(query) == strings.TrimSpace(currentCursorSQL):
		label = "cursor"
	default:
		for _, entity := range bootstrapEntities {
			if strings.Contains(query, "FROM " + entitySpecs[entity].table + " AS t") {
				label = entity
				if !strings.Contains(query, "family_id = $1::uuid") || !strings.Contains(query, "jsonb_agg") {
					return nil, errors.New("bootstrap entity query lost family scope or aggregation")
				}
				break
			}
		}
	}
	if label == "" { return nil, fmt.Errorf("unexpected bootstrap SQL: %s", query) }
	if label != "device" && label != "saved_checkpoint" && label != "checkpoint" && (len(args) != 1 || args[0].Value != s.familyID) {
		return nil, errors.New("bootstrap query lost family scope")
	}
	s.queries = append(s.queries, label)
	if s.failAt == label { return nil, s.queryErr }
	if label == "device" {
		if s.emptyDevice { return &bootstrapSnapshotRows{}, nil }
		return &bootstrapSnapshotRows{values: []driver.Value{"33333333-3333-4333-8333-333333333333"}}, nil
	}
	if label == "saved_checkpoint" {
		if s.emptyCheckpoint { return &bootstrapSnapshotRows{}, nil }
		if strings.Contains(query, "SELECT state,") {
			return &bootstrapSnapshotRows{values: []driver.Value{s.checkpointState, s.savedCheckpoint, s.savedCursor}}, nil
		}
		return &bootstrapSnapshotRows{values: []driver.Value{s.savedCheckpoint, s.savedCursor}}, nil
	}
	if label == "checkpoint" {
		s.checkpointWrites++
		s.checkpointArgs = append([]driver.NamedValue(nil), args...)
		if len(args) == 3 {
			c.pendingCheckpoint = &bootstrapSnapshotCheckpoint{checkpoint: s.checkpoint, cursor: args[2].Value.(int64), state: "pending"}
			return &bootstrapSnapshotRows{values: []driver.Value{"pending", s.checkpoint, args[2].Value}}, nil
		}
		token := s.savedCheckpoint
		if s.emptyCheckpoint { token = s.checkpoint }
		if args[5].Value != nil { token = args[5].Value.(string) }
		c.pendingCheckpoint = &bootstrapSnapshotCheckpoint{checkpoint: token, cursor: args[4].Value.(int64), state: "confirmed"}
		return &bootstrapSnapshotRows{values: []driver.Value{"confirmed", token}}, nil
	}
	if label == "family" && s.emptyFamily { return &bootstrapSnapshotRows{}, nil }
	if label == "cursor" { return &bootstrapSnapshotRows{values: []driver.Value{s.cursorValue}}, nil }
	var raw string
	if label == s.invalidJSONAt {
		raw = "{invalid-json"
	} else if label == "family" {
		raw = fmt.Sprintf(`{"id":%q,"name":"snapshot family"}`, s.familyID)
	} else {
		// Include a tombstone: authoritative snapshots must not quietly drop it.
		raw = fmt.Sprintf(`[{"id":%q,"version":3,"quantity":8,"deleted_at":"2026-10-01T00:00:00Z"}]`, label+"-record")
	}
	return &bootstrapSnapshotRows{values: []driver.Value{[]byte(raw)}}, nil
}
func (c *bootstrapSnapshotConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if err := ctx.Err(); err != nil { return nil, err }
	s := c.state
	s.mu.Lock()
	defer s.mu.Unlock()
	if !c.inTx || s.options.ReadOnly { return nil, errors.New("confirmation write escaped read-write transaction") }
	label := ""
	switch {
	case strings.Contains(query, "UPDATE sync_devices SET last_seen_at"):
		label = "update_device"
		if len(args) != 3 || args[0].Value != s.deviceID || args[1].Value != s.familyID || args[2].Value != s.cursorValue { return nil, errors.New("device update lost scope or server cursor") }
	case strings.Contains(query, "INSERT INTO sync_audit_log"):
		label = "audit"
		if len(args) != 7 || args[0].Value != s.familyID || args[1].Value != s.deviceID { return nil, errors.New("confirmation audit lost scope") }
		var details struct {
			Mode syncdomain.BootstrapMode `json:"mode"`
			SnapshotCursor int64 `json:"snapshot_cursor"`
		}
		raw, ok := args[6].Value.([]byte)
		if !ok {
			return nil, errors.New("confirmation audit details must be JSON bytes")
		}
		if err := json.Unmarshal(raw, &details); err != nil {
			return nil, err
		}
		if len(s.checkpointArgs) != 6 || string(details.Mode) != s.checkpointArgs[3].Value || details.SnapshotCursor != s.checkpointArgs[4].Value {
			return nil, errors.New("confirmation audit mode/cursor differs from saved checkpoint")
		}
	default:
		return nil, fmt.Errorf("unexpected confirmation exec: %s", query)
	}
	s.executions = append(s.executions, label)
	if s.failAt == label { return nil, s.queryErr }
	return driver.RowsAffected(1), nil
}

func (tx *bootstrapSnapshotTx) Commit() error {
	s := tx.state
	s.mu.Lock()
	defer s.mu.Unlock()
	s.commits++
	if s.commitErr == nil && tx.conn.pendingCheckpoint != nil {
		checkpoint := tx.conn.pendingCheckpoint
		s.savedCheckpoint, s.savedCursor, s.checkpointState = checkpoint.checkpoint, checkpoint.cursor, checkpoint.state
		s.emptyCheckpoint = false
	}
	tx.conn.pendingCheckpoint = nil
	s.active = false
	tx.conn.inTx = false
	return s.commitErr
}
func (tx *bootstrapSnapshotTx) Rollback() error {
	s := tx.state
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rollbacks++
	tx.conn.pendingCheckpoint = nil
	s.active = false
	tx.conn.inTx = false
	return nil
}
func (r *bootstrapSnapshotRows) Columns() []string {
	columns := []string{"snapshot_value"}
	for i := 1; i < len(r.values); i++ { columns = append(columns, fmt.Sprintf("value_%d", i)) }
	return columns
}
func (r *bootstrapSnapshotRows) Close() error { return nil }
func (r *bootstrapSnapshotRows) Next(dest []driver.Value) error {
	if r.done || r.values == nil { return io.EOF }
	r.done = true
	copy(dest, r.values)
	return nil
}

func newBootstrapSnapshotTestRepository(t *testing.T) (*Repository, *bootstrapSnapshotDriverState) {
	t.Helper()
	s := &bootstrapSnapshotDriverState{
		familyID: "11111111-1111-4111-8111-111111111111",
		cursorValue: int64(42),
		deviceID: "22222222-2222-4222-8222-222222222222",
		checkpoint: "66666666-6666-4666-8666-666666666666",
		savedCheckpoint: "44444444-4444-4444-8444-444444444444",
		savedCursor: 42,
		checkpointState: "pending",
	}
	db := sql.OpenDB(&bootstrapSnapshotConnector{state: s})
	// A pool read while a transaction owns this connection gets another
	// connection, and is rejected by the SQL driver/pool ownership check.
	t.Cleanup(func() { _ = db.Close() })
	return New(db), s
}

func assertBootstrapSnapshotTransaction(t *testing.T, s *bootstrapSnapshotDriverState) {
	t.Helper()
	if s.begins != 1 || s.options.Isolation != driver.IsolationLevel(sql.LevelRepeatableRead) || !s.options.ReadOnly {
		t.Fatalf("snapshot transaction: begins=%d, options=%+v; want one read-only RepeatableRead transaction", s.begins, s.options)
	}
	if s.outsideReads != 0 || s.active {
		t.Fatalf("transaction leaked: outside reads=%d, active=%v", s.outsideReads, s.active)
	}
}

func TestReadBootstrapUsesOneReadOnlyRepeatableReadTransaction(t *testing.T) {
	repository, s := newBootstrapSnapshotTestRepository(t)
	snapshot, err := repository.ReadBootstrap(context.Background(), s.familyID)
	if err != nil { t.Fatalf("ReadBootstrap: %v", err) }
	assertBootstrapSnapshotTransaction(t, s)
	if s.commits != 1 || s.rollbacks != 0 {
		t.Fatalf("success lifecycle: commits=%d, rollbacks=%d", s.commits, s.rollbacks)
	}
	wantQueries := append([]string{"family"}, bootstrapEntities...)
	wantQueries = append(wantQueries, "cursor")
	if !reflect.DeepEqual(s.queries, wantQueries) {
		t.Fatalf("transaction queries = %v, want %v", s.queries, wantQueries)
	}
	if snapshot.Family["id"] != s.familyID || snapshot.ServerCursor != 42 || !snapshot.MergeRequired {
		t.Fatalf("wrong family/cursor: %+v", snapshot)
	}
	if snapshot.SchemaVersion != syncdomain.DefaultSchemaVersion || snapshot.SyncProtocolVersion != syncdomain.DefaultSyncProtocolVersion || len(snapshot.AvailableModes) != 3 {
		t.Fatalf("bootstrap metadata lost: %+v", snapshot)
	}
	if len(snapshot.Snapshot) != len(bootstrapEntities) { t.Fatal("snapshot missing entities") }
	for _, entity := range bootstrapEntities {
		records, ok := snapshot.Snapshot[entity].([]map[string]any)
		if !ok || len(records) != 1 || records[0]["id"] != entity+"-record" || records[0]["deleted_at"] == nil {
			t.Fatalf("%s records or tombstone missing: %#v", entity, snapshot.Snapshot[entity])
		}
	}
}

func TestReadBootstrapZeroCursorIsNotMergeRequired(t *testing.T) {
	repository, s := newBootstrapSnapshotTestRepository(t)
	s.cursorValue = int64(0)
	snapshot, err := repository.ReadBootstrap(context.Background(), s.familyID)
	if err != nil { t.Fatal(err) }
	if snapshot.ServerCursor != 0 || snapshot.MergeRequired { t.Fatalf("empty change log: %+v", snapshot) }
	assertBootstrapSnapshotTransaction(t, s)
}

func TestReadBootstrapRollsBackQueryAndDecodeErrorsWithoutPartialResult(t *testing.T) {
	labels := append([]string{"family"}, bootstrapEntities...)
	labels = append(labels, "cursor")
	for _, label := range labels {
		t.Run("query/"+label, func(t *testing.T) {
			repository, s := newBootstrapSnapshotTestRepository(t)
			injected := errors.New("injected snapshot query failure")
			s.failAt, s.queryErr = label, injected
			snapshot, err := repository.ReadBootstrap(context.Background(), s.familyID)
			if !errors.Is(err, injected) { t.Fatalf("query error not propagated: %v", err) }
			assertEmptyBootstrapSnapshot(t, snapshot)
			assertBootstrapSnapshotTransaction(t, s)
			if s.commits != 0 || s.rollbacks != 1 || s.queries[len(s.queries)-1] != label {
				t.Fatalf("failed query lifecycle: commits=%d, rollbacks=%d, queries=%v", s.commits, s.rollbacks, s.queries)
			}
		})
		if label == "cursor" { continue }
		t.Run("decode/"+label, func(t *testing.T) {
			repository, s := newBootstrapSnapshotTestRepository(t)
			s.invalidJSONAt = label
			snapshot, err := repository.ReadBootstrap(context.Background(), s.familyID)
			if err == nil { t.Fatal("malformed JSON accepted") }
			assertEmptyBootstrapSnapshot(t, snapshot)
			assertBootstrapSnapshotTransaction(t, s)
			if s.commits != 0 || s.rollbacks != 1 || s.queries[len(s.queries)-1] != label {
				t.Fatalf("decode error did not stop and roll back: %+v", s)
			}
		})
	}
}

func TestReadBootstrapMissingFamilyRollsBack(t *testing.T) {
	repository, s := newBootstrapSnapshotTestRepository(t)
	s.emptyFamily = true
	snapshot, err := repository.ReadBootstrap(context.Background(), s.familyID)
	if !errors.Is(err, syncdomain.ErrNotFound) { t.Fatalf("missing family: %v", err) }
	assertEmptyBootstrapSnapshot(t, snapshot)
	assertBootstrapSnapshotTransaction(t, s)
	if s.rollbacks != 1 || s.commits != 0 || !reflect.DeepEqual(s.queries, []string{"family"}) {
		t.Fatalf("missing family lifecycle: %+v", s)
	}
}

func TestReadBootstrapCursorScanFailureRollsBack(t *testing.T) {
	repository, s := newBootstrapSnapshotTestRepository(t)
	s.cursorValue = "invalid cursor"
	snapshot, err := repository.ReadBootstrap(context.Background(), s.familyID)
	if err == nil { t.Fatal("invalid cursor accepted") }
	assertEmptyBootstrapSnapshot(t, snapshot)
	assertBootstrapSnapshotTransaction(t, s)
	if s.rollbacks != 1 || s.commits != 0 { t.Fatalf("cursor scan lifecycle: %+v", s) }
}

func TestReadBootstrapBeginFailureReturnsNoSnapshot(t *testing.T) {
	repository, s := newBootstrapSnapshotTestRepository(t)
	s.beginErr = errors.New("injected begin failure")
	snapshot, err := repository.ReadBootstrap(context.Background(), s.familyID)
	if !errors.Is(err, s.beginErr) { t.Fatalf("begin error not propagated: %v", err) }
	assertEmptyBootstrapSnapshot(t, snapshot)
	assertBootstrapSnapshotTransaction(t, s)
	if len(s.queries) != 0 || s.commits != 0 || s.rollbacks != 0 { t.Fatalf("work after begin failure: %+v", s) }
}

func TestReadBootstrapCommitFailureReturnsNoSnapshot(t *testing.T) {
	repository, s := newBootstrapSnapshotTestRepository(t)
	s.commitErr = errors.New("injected commit failure")
	snapshot, err := repository.ReadBootstrap(context.Background(), s.familyID)
	if !errors.Is(err, s.commitErr) { t.Fatalf("commit error not propagated: %v", err) }
	assertEmptyBootstrapSnapshot(t, snapshot)
	assertBootstrapSnapshotTransaction(t, s)
	if s.commits != 1 || len(s.queries) != len(bootstrapEntities)+2 {
		t.Fatalf("commit failure lifecycle: %+v", s)
	}
	// database/sql marks a transaction done even if driver.Commit fails; the
	// deferred Rollback may return ErrTxDone without calling driver.Rollback.
}

func TestReadBootstrapUnconfiguredRepositoryReturnsNoSnapshot(t *testing.T) {
	for _, repository := range []*Repository{nil, New(nil)} {
		snapshot, err := repository.ReadBootstrap(context.Background(), "family")
		if err == nil { t.Fatal("unconfigured database accepted") }
		assertEmptyBootstrapSnapshot(t, snapshot)
	}
}

func assertEmptyBootstrapSnapshot(t *testing.T, snapshot syncdomain.BootstrapSnapshot) {
	t.Helper()
	if !reflect.DeepEqual(snapshot, syncdomain.BootstrapSnapshot{}) {
		t.Fatalf("error returned a partial/success-shaped snapshot: %+v", snapshot)
	}
}

func TestReadBootstrapForDeviceReusesCheckpointForUnchangedSnapshot(t *testing.T) {
	for _, state := range []string{"pending", "confirmed", "completed"} {
		for _, cursor := range []int64{0, 42} {
			t.Run(fmt.Sprintf("%s/cursor_%d", state, cursor), func(t *testing.T) {
				repository, s := newBootstrapSnapshotTestRepository(t)
				s.checkpointState = state
				s.cursorValue, s.savedCursor = cursor, cursor
				for read := 0; read < 2; read++ {
					resetBootstrapSnapshotObservations(s)
					snapshot, err := repository.ReadBootstrapForDevice(context.Background(), s.familyID, s.deviceID)
					if err != nil {
						t.Fatalf("device bootstrap: %v", err)
					}
					assertBootstrapReadWriteTransaction(t, s, sql.LevelRepeatableRead)
					wantQueries := append([]string{"device", "family"}, bootstrapEntities...)
					wantQueries = append(wantQueries, "cursor", "saved_checkpoint")
					if !reflect.DeepEqual(s.queries, wantQueries) || s.commits != 1 || s.rollbacks != 0 || s.checkpointWrites != 0 || len(s.executions) != 0 {
						t.Fatalf("unchanged snapshot wrote or rotated its checkpoint: %+v", s)
					}
					if snapshot.ServerCursor != cursor || snapshot.Checkpoint != s.savedCheckpoint || snapshot.BootstrapState != state || len(snapshot.Snapshot) != len(bootstrapEntities) {
						t.Fatalf("checkpoint/snapshot binding lost: %+v", snapshot)
					}
				}
				// An intervening unchanged GET must not invalidate the token
				// held by a client that is about to confirm this snapshot.
				resetBootstrapSnapshotObservations(s)
				confirmation, err := repository.ConfirmBootstrap(context.Background(), s.familyID, syncdomain.BootstrapConfirmRequest{
					DeviceID: s.deviceID, Mode: syncdomain.BootstrapModeJoinAndMerge, Checkpoint: s.savedCheckpoint, SnapshotCursor: cursor,
				})
				if err != nil {
					t.Fatalf("unchanged checkpoint confirmation: %v", err)
				}
				assertBootstrapReadWriteTransaction(t, s, sql.LevelSerializable)
				if !confirmation.Accepted || confirmation.Checkpoint != s.savedCheckpoint || s.checkpointWrites != 1 || s.commits != 1 {
					t.Fatalf("unchanged GET invalidated confirmation: confirmation=%+v, driver=%+v", confirmation, s)
				}
			})
		}
	}
}

func TestReadBootstrapForDeviceCreatesOrRefreshesCheckpoint(t *testing.T) {
	for _, reason := range []string{"missing", "changed_cursor", "empty_token", "invalid_token"} {
		t.Run(reason, func(t *testing.T) {
			repository, s := newBootstrapSnapshotTestRepository(t)
			s.checkpointState = "confirmed"
			switch reason {
			case "missing":
				s.emptyCheckpoint = true
			case "changed_cursor":
				s.savedCursor--
			case "empty_token":
				s.savedCheckpoint = ""
			case "invalid_token":
				s.savedCheckpoint = "not-a-uuid"
			}
			oldToken := s.savedCheckpoint
			snapshot, err := repository.ReadBootstrapForDevice(context.Background(), s.familyID, s.deviceID)
			if err != nil {
				t.Fatalf("device bootstrap: %v", err)
			}
			assertBootstrapReadWriteTransaction(t, s, sql.LevelRepeatableRead)
			wantQueries := append([]string{"device", "family"}, bootstrapEntities...)
			wantQueries = append(wantQueries, "cursor", "saved_checkpoint", "checkpoint")
			if !reflect.DeepEqual(s.queries, wantQueries) || s.commits != 1 || s.rollbacks != 0 || s.checkpointWrites != 1 {
				t.Fatalf("refreshed checkpoint lifecycle: %+v", s)
			}
			if snapshot.ServerCursor != 42 || snapshot.Checkpoint != s.checkpoint || snapshot.Checkpoint == oldToken || snapshot.BootstrapState != "pending" || s.savedCheckpoint != snapshot.Checkpoint || s.savedCursor != snapshot.ServerCursor || s.checkpointState != "pending" {
				t.Fatalf("refresh did not invalidate confirmation and persist snapshot binding: snapshot=%+v, driver=%+v", snapshot, s)
			}
			resetBootstrapSnapshotObservations(s)
			repeated, err := repository.ReadBootstrapForDevice(context.Background(), s.familyID, s.deviceID)
			if err != nil {
				t.Fatalf("repeat device bootstrap: %v", err)
			}
			assertBootstrapReadWriteTransaction(t, s, sql.LevelRepeatableRead)
			if repeated.Checkpoint != snapshot.Checkpoint || repeated.ServerCursor != snapshot.ServerCursor || repeated.BootstrapState != "pending" || s.checkpointWrites != 0 || s.commits != 1 {
				t.Fatalf("repeat GET rotated refreshed checkpoint: snapshot=%+v, driver=%+v", repeated, s)
			}
		})
	}
}

func TestReadBootstrapForDeviceRefreshRequiresMatchingConfirmation(t *testing.T) {
	for _, mode := range []syncdomain.BootstrapMode{syncdomain.BootstrapModeJoinAndMerge, syncdomain.BootstrapModeCreateNewFamily} {
		t.Run(string(mode), func(t *testing.T) {
			repository, s := newBootstrapSnapshotTestRepository(t)
			oldToken, oldCursor := s.savedCheckpoint, s.savedCursor
			s.checkpointState = "confirmed"
			s.cursorValue = oldCursor + 1
			snapshot, err := repository.ReadBootstrapForDevice(context.Background(), s.familyID, s.deviceID)
			if err != nil {
				t.Fatal(err)
			}
			assertBootstrapReadWriteTransaction(t, s, sql.LevelRepeatableRead)
			if snapshot.Checkpoint == oldToken || snapshot.ServerCursor != oldCursor + 1 || snapshot.BootstrapState != "pending" {
				t.Fatalf("cursor change failed to invalidate old confirmation: %+v", snapshot)
			}
			for _, stale := range []struct {
				name string
				token string
				cursor int64
			}{
				{name: "old_pair", token: oldToken, cursor: oldCursor},
				{name: "old_token", token: oldToken, cursor: snapshot.ServerCursor},
				{name: "old_cursor", token: snapshot.Checkpoint, cursor: oldCursor},
			} {
				t.Run(stale.name, func(t *testing.T) {
					resetBootstrapSnapshotObservations(s)
					confirmation, err := repository.ConfirmBootstrap(context.Background(), s.familyID, syncdomain.BootstrapConfirmRequest{
						DeviceID: s.deviceID, Mode: mode, Checkpoint: stale.token, SnapshotCursor: stale.cursor,
					})
					var businessErr *syncdomain.BusinessError
					if !errors.As(err, &businessErr) || businessErr.Code != "BOOTSTRAP_CHECKPOINT_STALE" {
						t.Fatalf("stale checkpoint error: %v", err)
					}
					if !reflect.DeepEqual(confirmation, syncdomain.BootstrapConfirmation{}) {
						t.Fatalf("stale checkpoint returned success: %+v", confirmation)
					}
					assertBootstrapReadWriteTransaction(t, s, sql.LevelSerializable)
					if s.checkpointWrites != 0 || len(s.executions) != 0 || s.commits != 0 || s.rollbacks != 1 || !reflect.DeepEqual(s.queries, []string{"device", "saved_checkpoint"}) || s.savedCheckpoint != snapshot.Checkpoint || s.savedCursor != snapshot.ServerCursor || s.checkpointState != "pending" {
						t.Fatalf("stale confirmation changed saved checkpoint: %+v", s)
					}
				})
			}
			resetBootstrapSnapshotObservations(s)
			confirmation, err := repository.ConfirmBootstrap(context.Background(), s.familyID, syncdomain.BootstrapConfirmRequest{
				DeviceID: s.deviceID, Mode: mode, Checkpoint: snapshot.Checkpoint, SnapshotCursor: snapshot.ServerCursor,
			})
			if err != nil {
				t.Fatalf("fresh checkpoint confirmation: %v", err)
			}
			assertBootstrapReadWriteTransaction(t, s, sql.LevelSerializable)
			if !confirmation.Accepted || confirmation.Checkpoint != snapshot.Checkpoint || confirmation.ServerCursor != snapshot.ServerCursor || confirmation.BootstrapState != "confirmed" || s.checkpointWrites != 1 || s.commits != 1 || !reflect.DeepEqual(s.executions, []string{"update_device", "audit"}) {
				t.Fatalf("fresh confirmation receipt or lifecycle lost: confirmation=%+v, driver=%+v", confirmation, s)
			}
			resetBootstrapSnapshotObservations(s)
			repeated, err := repository.ReadBootstrapForDevice(context.Background(), s.familyID, s.deviceID)
			if err != nil {
				t.Fatal(err)
			}
			assertBootstrapReadWriteTransaction(t, s, sql.LevelRepeatableRead)
			if repeated.Checkpoint != snapshot.Checkpoint || repeated.BootstrapState != "confirmed" || s.checkpointWrites != 0 || s.commits != 1 {
				t.Fatalf("GET invalidated fresh confirmation: snapshot=%+v, driver=%+v", repeated, s)
			}
		})
	}
}

func TestReadBootstrapForDeviceErrorsNeverReturnPartialCheckpoint(t *testing.T) {
	for _, failure := range []string{"device", "products", "saved_checkpoint", "checkpoint", "commit"} {
		t.Run(failure, func(t *testing.T) {
			repository, s := newBootstrapSnapshotTestRepository(t)
			s.checkpointState = "confirmed"
			s.savedCursor-- // Exercise the refresh write as well as checkpoint reads.
			oldToken, oldCursor, oldState := s.savedCheckpoint, s.savedCursor, s.checkpointState
			injected := errors.New("injected device bootstrap failure")
			if failure == "commit" { s.commitErr = injected } else { s.failAt, s.queryErr = failure, injected }
			snapshot, err := repository.ReadBootstrapForDevice(context.Background(), s.familyID, s.deviceID)
			if !errors.Is(err, injected) { t.Fatalf("device bootstrap error: %v", err) }
			assertEmptyBootstrapSnapshot(t, snapshot)
			if s.savedCheckpoint != oldToken || s.savedCursor != oldCursor || s.checkpointState != oldState {
				t.Fatalf("failed refresh persisted a partial checkpoint: %+v", s)
			}
			assertBootstrapReadWriteTransaction(t, s, sql.LevelRepeatableRead)
			if failure == "commit" {
				if s.commits != 1 { t.Fatal("commit was not attempted") }
			} else if s.commits != 0 || s.rollbacks != 1 {
				t.Fatalf("device query failure did not roll back: %+v", s)
			}
		})
	}
}

func TestReadBootstrapForDeviceMissingOrRevokedDeviceStopsBeforeSnapshot(t *testing.T) {
	repository, s := newBootstrapSnapshotTestRepository(t)
	s.emptyDevice = true
	snapshot, err := repository.ReadBootstrapForDevice(context.Background(), s.familyID, s.deviceID)
	if !errors.Is(err, syncdomain.ErrDeviceNotFound) { t.Fatalf("device not found: %v", err) }
	assertEmptyBootstrapSnapshot(t, snapshot)
	assertBootstrapReadWriteTransaction(t, s, sql.LevelRepeatableRead)
	if !reflect.DeepEqual(s.queries, []string{"device"}) || s.checkpointWrites != 0 || s.rollbacks != 1 || s.commits != 0 {
		t.Fatalf("missing device read snapshot or checkpoint: %+v", s)
	}
}

func TestConfirmBootstrapRejectsStaleCheckpointBeforeWrites(t *testing.T) {
	for _, failure := range []string{"missing_record", "missing_token", "wrong_token", "malformed_token", "wrong_cursor"} {
		t.Run(failure, func(t *testing.T) {
			repository, s := newBootstrapSnapshotTestRepository(t)
			request := syncdomain.BootstrapConfirmRequest{DeviceID: s.deviceID, Mode: syncdomain.BootstrapModeJoinAndMerge, Checkpoint: s.savedCheckpoint, SnapshotCursor: s.savedCursor}
			switch failure {
			case "missing_record": s.emptyCheckpoint = true
			case "missing_token": request.Checkpoint = ""
			case "wrong_token": request.Checkpoint = "55555555-5555-4555-8555-555555555555"
			case "malformed_token": request.Checkpoint = "not-a-uuid"
			case "wrong_cursor": request.SnapshotCursor--
			}
			confirmation, err := repository.ConfirmBootstrap(context.Background(), s.familyID, request)
			var businessErr *syncdomain.BusinessError
			if !errors.As(err, &businessErr) || businessErr.Code != "BOOTSTRAP_CHECKPOINT_STALE" { t.Fatalf("stale checkpoint error: %v", err) }
			if !reflect.DeepEqual(confirmation, syncdomain.BootstrapConfirmation{}) { t.Fatalf("stale checkpoint returned success: %+v", confirmation) }
			assertBootstrapReadWriteTransaction(t, s, sql.LevelSerializable)
			if s.checkpointWrites != 0 || len(s.executions) != 0 || s.commits != 0 || s.rollbacks != 1 || !reflect.DeepEqual(s.queries, []string{"device", "saved_checkpoint"}) {
				t.Fatalf("stale checkpoint caused writes: %+v", s)
			}
		})
	}
}

func TestConfirmBootstrapKeepLocalIgnoresClientCheckpoint(t *testing.T) {
	for _, existing := range []bool{false, true} {
		for _, checkpoint := range []string{"", "55555555-5555-4555-8555-555555555555", "not-a-uuid", " '; SELECT 1; --", "  ", "客户端乱token"} {
			t.Run(fmt.Sprintf("existing_%t/token_%s", existing, checkpoint), func(t *testing.T) {
				repository, s := newBootstrapSnapshotTestRepository(t)
				s.emptyCheckpoint = !existing
				wantToken := s.checkpoint
				if existing {
					wantToken = s.savedCheckpoint
				}
				confirmation, err := repository.ConfirmBootstrap(context.Background(), s.familyID, syncdomain.BootstrapConfirmRequest{
					DeviceID: s.deviceID, Mode: syncdomain.BootstrapModeKeepLocalOnly, Checkpoint: checkpoint, SnapshotCursor: 0,
				})
				if err != nil {
					t.Fatalf("keep-local unexpectedly consumes client checkpoint: %v", err)
				}
				assertBootstrapReadWriteTransaction(t, s, sql.LevelSerializable)
				if !confirmation.Accepted || confirmation.Checkpoint != wantToken || confirmation.BootstrapState != "confirmed" || s.checkpointWrites != 1 || s.commits != 1 || !reflect.DeepEqual(s.queries, []string{"device", "cursor", "checkpoint"}) || !reflect.DeepEqual(s.executions, []string{"update_device", "audit"}) {
					t.Fatalf("keep-local confirmation lifecycle: confirmation=%+v, driver=%+v", confirmation, s)
				}
				if len(s.checkpointArgs) != 6 || s.checkpointArgs[5].Value != nil || s.savedCheckpoint != wantToken {
					t.Fatalf("keep-local forwarded or saved the client token: %+v", s)
				}
			})
		}
	}
}

func TestConfirmBootstrapRemoteModesStillRejectFutureSnapshotCursor(t *testing.T) {
	for _, mode := range []syncdomain.BootstrapMode{syncdomain.BootstrapModeJoinAndMerge, syncdomain.BootstrapModeCreateNewFamily} {
		t.Run(string(mode), func(t *testing.T) {
			repository, s := newBootstrapSnapshotTestRepository(t)
			s.savedCursor = 43
			confirmation, err := repository.ConfirmBootstrap(context.Background(), s.familyID, syncdomain.BootstrapConfirmRequest{
				DeviceID: s.deviceID, Mode: mode, Checkpoint: s.savedCheckpoint, SnapshotCursor: s.savedCursor,
			})
			var businessErr *syncdomain.BusinessError
			if !errors.As(err, &businessErr) || businessErr.Code != "INVALID_CURSOR" {
				t.Fatalf("remote mode no longer rejects future snapshot cursor: %v", err)
			}
			if !reflect.DeepEqual(confirmation, syncdomain.BootstrapConfirmation{}) {
				t.Fatalf("future snapshot cursor returned success: %+v", confirmation)
			}
			assertBootstrapReadWriteTransaction(t, s, sql.LevelSerializable)
			if s.checkpointWrites != 0 || len(s.executions) != 0 || s.commits != 0 || s.rollbacks != 1 || s.savedCursor != 43 || !reflect.DeepEqual(s.queries, []string{"device", "saved_checkpoint", "cursor"}) {
				t.Fatalf("future remote cursor caused writes or bypassed exact validation: %+v", s)
			}
		})
	}
}

func TestConfirmBootstrapKeepLocalIgnoresClientSnapshotCursor(t *testing.T) {
	for _, existing := range []bool{false, true} {
		for _, cursor := range []int64{-1, 0, 42, 43, 9223372036854775807} {
			t.Run(fmt.Sprintf("existing_%t/cursor_%d", existing, cursor), func(t *testing.T) {
				repository, s := newBootstrapSnapshotTestRepository(t)
				s.emptyCheckpoint = !existing
				wantToken := s.checkpoint
				if existing {
					wantToken = s.savedCheckpoint
				}
				request := syncdomain.BootstrapConfirmRequest{
					DeviceID: s.deviceID, Mode: syncdomain.BootstrapModeKeepLocalOnly,
					Checkpoint: "not-a-uuid", SnapshotCursor: cursor,
				}
				confirmation, err := repository.ConfirmBootstrap(context.Background(), s.familyID, request)
				if err != nil {
					t.Fatalf("keep-local was blocked by untrusted snapshot cursor %d: %v", cursor, err)
				}
				assertBootstrapReadWriteTransaction(t, s, sql.LevelSerializable)
				if !confirmation.Accepted || confirmation.ServerCursor != 42 || confirmation.Checkpoint != wantToken || confirmation.BootstrapState != "confirmed" {
					t.Fatalf("keep-local confirmation receipt: %+v", confirmation)
				}
				if s.checkpointWrites != 1 || s.commits != 1 || s.rollbacks != 0 || !reflect.DeepEqual(s.queries, []string{"device", "cursor", "checkpoint"}) || !reflect.DeepEqual(s.executions, []string{"update_device", "audit"}) {
					t.Fatalf("keep-local confirmation lifecycle: %+v", s)
				}
				if len(s.checkpointArgs) != 6 || s.checkpointArgs[3].Value != string(syncdomain.BootstrapModeKeepLocalOnly) || s.checkpointArgs[4].Value != int64(0) || s.checkpointArgs[5].Value != nil || s.savedCursor != 0 || s.savedCheckpoint != wantToken {
					t.Fatalf("keep-local changed mode or persisted client snapshot identifiers: %+v", s)
				}
				if request.Mode != syncdomain.BootstrapModeKeepLocalOnly || request.SnapshotCursor != cursor {
					t.Fatalf("confirmation mutated the caller's request: %+v", request)
				}
			})
		}
	}
}

// Reset call observations, not committed records, between lifecycle operations.
func resetBootstrapSnapshotObservations(s *bootstrapSnapshotDriverState) {
	s.begins, s.commits, s.rollbacks, s.checkpointWrites = 0, 0, 0, 0
	s.queries, s.executions, s.checkpointArgs = nil, nil, nil
}

func assertBootstrapReadWriteTransaction(t *testing.T, s *bootstrapSnapshotDriverState, isolation sql.IsolationLevel) {
	t.Helper()
	if s.begins != 1 || s.options.Isolation != driver.IsolationLevel(isolation) || s.options.ReadOnly || s.outsideReads != 0 || s.active {
		t.Fatalf("read-write transaction: begins=%d, options=%+v, outside=%d, active=%v", s.begins, s.options, s.outsideReads, s.active)
	}
}
