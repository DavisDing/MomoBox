package family_test

import (
	"context"
	"errors"
	"testing"
	"time"

	family "github.com/momobox/backend/internal/family"
)

type clock struct{ now time.Time }

func (c clock) Now() time.Time { return c.now }

type ids struct{ n int }

func (g *ids) NewID() (string, error) { g.n++; return "id-" + string(rune('0'+g.n)), nil }

type codes struct{}

func (codes) NewCode() (string, error) { return "invite-code-123456789", nil }

type families struct {
	values  map[string]family.Family
	current map[string]string
	owners  map[string]family.Membership
}

func (r *families) CreateWithOwner(_ context.Context, f family.Family, owner family.Membership) error {
	r.values[f.ID] = f
	r.owners[f.ID] = owner
	return nil
}
func (r *families) FindByID(_ context.Context, id string) (family.Family, error) {
	f, ok := r.values[id]
	if !ok {
		return family.Family{}, errors.New("not found")
	}
	return f, nil
}
func (r *families) FindCurrentForUser(_ context.Context, user string) (family.Family, family.Membership, error) {
	id, ok := r.current[user]
	if !ok {
		return family.Family{}, family.Membership{}, errors.New("not found")
	}
	f := r.values[id]
	return f, r.owners[id], nil
}
func (r *families) SetCurrentForUser(_ context.Context, user, id string) error {
	r.current[user] = id
	return nil
}

type members struct {
	values map[string]family.Membership
	listed string
}

func key(f, u string) string { return f + ":" + u }
func (r *members) Find(_ context.Context, f, u string) (family.Membership, error) {
	m, ok := r.values[key(f, u)]
	if !ok {
		return family.Membership{}, errors.New("not found")
	}
	return m, nil
}
func (r *members) List(_ context.Context, f string) ([]family.FamilyMember, error) {
	r.listed = f
	return []family.FamilyMember{{UserSummary: family.UserSummary{ID: "owner"}, Role: family.RoleOwner}}, nil
}

type invites struct{ values map[string]family.Invite }

func (r *invites) Create(_ context.Context, i family.Invite) error {
	r.values[i.CodeHash] = i
	return nil
}
func (r *invites) FindByHash(_ context.Context, h string) (family.Invite, error) {
	i, ok := r.values[h]
	if !ok {
		return family.Invite{}, errors.New("not found")
	}
	return i, nil
}

type joiner struct {
	repo    *invites
	fam     *families
	members *members
}

func (r *joiner) JoinWithInvite(_ context.Context, hash, user string, now time.Time) (family.Family, family.Membership, error) {
	i, ok := r.repo.values[hash]
	if !ok {
		return family.Family{}, family.Membership{}, errors.New("invalid")
	}
	if !i.ExpiresAt.After(now) {
		return family.Family{}, family.Membership{}, &family.ServiceError{Code: family.CodeInviteExpired, Message: "expired"}
	}
	if i.RemainingUses() <= 0 {
		return family.Family{}, family.Membership{}, &family.ServiceError{Code: family.CodeInviteExhausted, Message: "used"}
	}
	if _, exists := r.members.values[key(i.FamilyID, user)]; exists {
		return family.Family{}, family.Membership{}, &family.ServiceError{Code: family.CodeAlreadyMember, Message: "member"}
	}
	i.UsedCount++
	r.repo.values[hash] = i
	m := family.Membership{FamilyID: i.FamilyID, UserID: user, Role: family.RoleMember, JoinedAt: now}
	r.members.values[key(i.FamilyID, user)] = m
	return r.fam.values[i.FamilyID], m, nil
}

func newFamilyService(t *testing.T) (*family.Service, *families, *members, *invites) {
	t.Helper()
	f := &families{values: map[string]family.Family{}, current: map[string]string{}, owners: map[string]family.Membership{}}
	m := &members{values: map[string]family.Membership{}}
	i := &invites{values: map[string]family.Invite{}}
	service, err := family.NewService(f, m, i, &joiner{repo: i, fam: f, members: m}, &ids{}, codes{}, clock{now: time.Date(2026, 9, 20, 10, 30, 0, 0, time.UTC)}, []byte("pepper"))
	if err != nil {
		t.Fatal(err)
	}
	return service, f, m, i
}

func TestCreateCurrentInviteAndJoin(t *testing.T) {
	service, f, members, invites := newFamilyService(t)
	created, err := service.CreateFamily(context.Background(), "owner", family.CreateFamilyRequest{Name: "  Momo Home  "})
	if err != nil {
		t.Fatal(err)
	}
	if created.Family.Name != "Momo Home" || created.Membership.Role != family.RoleOwner {
		t.Fatalf("unexpected create response: %+v", created)
	}
	current, err := service.CurrentFamily(context.Background(), "owner")
	if err != nil || current.Family.ID != created.Family.ID {
		t.Fatalf("current family = %+v, err=%v", current, err)
	}
	members.values[key(created.Family.ID, "owner")] = created.Membership
	invite, err := service.CreateInvite(context.Background(), "owner", created.Family.ID, family.CreateInviteRequest{ExpiresInHours: 24, MaxUses: 1})
	if err != nil {
		t.Fatal(err)
	}
	if invite.Code == "" || invite.RemainingUses != 1 || len(invites.values) != 1 {
		t.Fatalf("unexpected invite: %+v", invite)
	}
	joined, err := service.Join(context.Background(), "member", family.JoinFamilyRequest{Code: invite.Code})
	if err != nil {
		t.Fatal(err)
	}
	if joined.Membership.Role != family.RoleMember || f.current["member"] != created.Family.ID {
		t.Fatalf("unexpected join: %+v", joined)
	}
}

func TestMemberCannotCreateInviteAndAllRolesCanView(t *testing.T) {
	service, _, members, _ := newFamilyService(t)
	created, _ := service.CreateFamily(context.Background(), "owner", family.CreateFamilyRequest{Name: "Home"})
	members.values[key(created.Family.ID, "member")] = family.Membership{FamilyID: created.Family.ID, UserID: "member", Role: family.RoleMember}
	if _, err := service.CreateInvite(context.Background(), "member", created.Family.ID, family.CreateInviteRequest{ExpiresInHours: 1, MaxUses: 1}); err == nil {
		t.Fatal("member created an invite")
	}
	listed, err := service.ListMembers(context.Background(), "member", created.Family.ID)
	if err != nil || len(listed.Members) != 1 {
		t.Fatalf("member list = %+v, err=%v", listed, err)
	}
	if members.listed != created.Family.ID {
		t.Fatalf("member list was not family scoped: %q", members.listed)
	}
}

func TestRoleMatrix(t *testing.T) {
	for _, role := range []family.Role{family.RoleOwner, family.RoleAdmin, family.RoleMember} {
		if !family.Authorize(role, family.PermissionView) {
			t.Fatalf("%s cannot view", role)
		}
	}
	if family.Authorize(family.RoleMember, family.PermissionCreateInvite) {
		t.Fatal("member can create invite")
	}
	if !family.Authorize(family.RoleAdmin, family.PermissionCreateInvite) || !family.Authorize(family.RoleOwner, family.PermissionRenameFamily) {
		t.Fatal("owner/admin permissions incorrect")
	}
	if family.Authorize(family.RoleAdmin, family.PermissionRenameFamily) {
		t.Fatal("admin can rename family")
	}
}
