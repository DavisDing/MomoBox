package homeassistant

import (
	"context"
	"errors"
	"testing"
)

type memoryExecutionRepo struct {
	value       CommandExecution
	exists      bool
	completeErr error
}

func (r *memoryExecutionRepo) Begin(_ context.Context, _, _, fingerprint string) (CommandExecution, bool, error) {
	if r.exists {
		return r.value, false, nil
	}
	r.exists = true
	r.value = CommandExecution{Status: "pending", Fingerprint: fingerprint}
	return r.value, true, nil
}
func (r *memoryExecutionRepo) Complete(_ context.Context, _, _, _ string, value CommandExecution) error {
	if r.completeErr != nil {
		return r.completeErr
	}
	r.value = value
	return nil
}

func TestExecutionLedgerReplaysReceiptAfterAuditOrSyncFailure(t *testing.T) {
	integration := contractIntegration("f", "i")
	entity := contractEntity("f", "i", "light.kitchen")
	service, _, _, _, audit, _, client := contractService(integration, entity, contractPermission("f", "i", entity.EntityID, RoleMember, CommandTurnOn))
	ledger := &memoryExecutionRepo{}
	service.Executions = ledger
	actor := Actor{FamilyID: "f", UserID: "u", Role: RoleMember, DeviceID: "d"}
	request := CommandRequest{RequestID: contractRequestID, Command: CommandTurnOn}
	audit.err = errors.New("audit unavailable")
	if _, err := service.ExecuteCommand(context.Background(), actor, "i", entity.EntityID, request); err == nil {
		t.Fatal("expected audit failure after external execution")
	}
	audit.err = nil
	receipt, err := service.ExecuteCommand(context.Background(), actor, "i", entity.EntityID, request)
	if err != nil || !receipt.Accepted || client.executeCalls != 1 || len(audit.logs) != 1 {
		t.Fatalf("retry repeated external command: %#v %v calls=%d", receipt, err, client.executeCalls)
	}
	request.Command = CommandTurnOff
	// Make this second command legal so the test reaches identity comparison.
	service.Permissions.(*contractPermissionRepo).items[permissionKey("f", "i", entity.EntityID, RoleMember)] = contractPermission("f", "i", entity.EntityID, RoleMember, CommandTurnOn, CommandTurnOff)
	if _, err := service.ExecuteCommand(context.Background(), actor, "i", entity.EntityID, request); businessCode(t, err) != CodeRequestReuse || client.executeCalls != 1 {
		t.Fatalf("changed request reused ledger: %v", err)
	}
}
func TestUnknownOrUnpersistedExecutionIsNeverAutomaticallyResent(t *testing.T) {
	for _, test := range []string{"timeout", "receipt failure"} {
		t.Run(test, func(t *testing.T) {
			integration := contractIntegration("f", "i")
			entity := contractEntity("f", "i", "light.kitchen")
			service, _, _, _, _, _, client := contractService(integration, entity, contractPermission("f", "i", entity.EntityID, RoleMember, CommandTurnOn))
			ledger := &memoryExecutionRepo{}
			service.Executions = ledger
			if test == "timeout" {
				client.executeErr = context.DeadlineExceeded
			} else {
				ledger.completeErr = errors.New("DB commit failed")
			}
			actor := Actor{FamilyID: "f", UserID: "u", Role: RoleMember}
			request := CommandRequest{RequestID: contractRequestID, Command: CommandTurnOn}
			for i := 0; i < 2; i++ {
				if _, err := service.ExecuteCommand(context.Background(), actor, "i", entity.EntityID, request); businessCode(t, err) != CodeCommandUnknown {
					t.Fatalf("expected unknown: %v", err)
				}
			}
			if client.executeCalls != 1 {
				t.Fatal("unknown execution resent")
			}
		})
	}
}
func TestUntrustedOrCrossIntegrationEventsAreRejected(t *testing.T) {
	actor := Actor{FamilyID: "f", UserID: "u", Role: RoleOwner}
	service := &Service{}
	event := HAEvent{IntegrationID: "i", EntityID: "light.kitchen", ApplianceRunID: "run1", Domain: "light", State: "completed"}
	for _, ctx := range []context.Context{context.Background(), TrustedEventContext(context.Background(), "other", "i"), TrustedEventContext(context.Background(), "f", "other")} {
		if _, err := service.ProcessHAEvent(ctx, actor, event); businessCode(t, err) != CodeForbidden {
			t.Fatalf("untrusted event accepted: %v", err)
		}
	}
}

func TestHAURLRejectsMetadataButAllowsLANAndLoopback(t *testing.T) {
	for _, url := range []string{"http://169.254.169.254", "http://[::ffff:169.254.169.254]", "http://100.100.100.200", "http://[fd00:ec2::254]", "http://metadata.google.internal", "http://0.0.0.0"} {
		if err := ValidateBaseURL(url); err == nil {
			t.Fatalf("metadata URL accepted %q", url)
		}
	}
	for _, url := range []string{"http://192.168.1.20:8123", "http://127.0.0.1:8123", "http://ha.local:8123", "https://[fd00::20]:8123"} {
		if err := ValidateBaseURL(url); err != nil {
			t.Fatalf("legitimate HA deployment rejected %q: %v", url, err)
		}
	}
}
