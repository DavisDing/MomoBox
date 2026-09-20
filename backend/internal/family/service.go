package family

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

type Service struct {
	families    FamilyRepository
	memberships MembershipRepository
	invites     InviteRepository
	joiner      FamilyJoinRepository
	ids         IDGenerator
	codes       CodeGenerator
	clock       Clock
	inviteHash  InviteCodeHasher
}

func NewService(families FamilyRepository, memberships MembershipRepository, invites InviteRepository, joiner FamilyJoinRepository, ids IDGenerator, codes CodeGenerator, clock Clock, invitePepper []byte) (*Service, error) {
	if families == nil || memberships == nil || invites == nil || joiner == nil || ids == nil || codes == nil || clock == nil {
		return nil, errors.New("family service dependencies must not be nil")
	}
	return &Service{families: families, memberships: memberships, invites: invites, joiner: joiner, ids: ids, codes: codes, clock: clock, inviteHash: InviteCodeHasher{Pepper: invitePepper}}, nil
}

func (s *Service) CreateFamily(ctx context.Context, userID string, request CreateFamilyRequest) (FamilyResponse, error) {
	var empty FamilyResponse
	if strings.TrimSpace(userID) == "" {
		return empty, newError(CodeUnauthorized, "user is required")
	}
	name := strings.TrimSpace(request.Name)
	if n := utf8.RuneCountInString(name); n < 1 || n > 120 {
		return empty, newError(CodeValidation, "family name must be 1-120 characters")
	}
	familyID, err := s.ids.NewID()
	if err != nil {
		return empty, err
	}
	now := s.clock.Now()
	family := Family{ID: familyID, Name: name, CreatedAt: now}
	membership := Membership{FamilyID: familyID, UserID: userID, Role: RoleOwner, JoinedAt: now}
	if err := s.families.CreateWithOwner(ctx, family, membership); err != nil {
		return empty, err
	}
	if err := s.families.SetCurrentForUser(ctx, userID, familyID); err != nil {
		return empty, err
	}
	return FamilyResponse{Family: family, Membership: membership}, nil
}

func (s *Service) CurrentFamily(ctx context.Context, userID string) (FamilyResponse, error) {
	var empty FamilyResponse
	if strings.TrimSpace(userID) == "" {
		return empty, newError(CodeUnauthorized, "user is required")
	}
	family, membership, err := s.families.FindCurrentForUser(ctx, userID)
	if err != nil {
		return empty, newError(CodeNotFound, "current family was not found")
	}
	if membership.UserID == "" {
		membership.UserID = userID
	}
	return FamilyResponse{Family: family, Membership: membership}, nil
}

func (s *Service) CreateInvite(ctx context.Context, userID, familyID string, request CreateInviteRequest) (InviteResponse, error) {
	var empty InviteResponse
	membership, err := s.requireMembership(ctx, familyID, userID)
	if err != nil {
		return empty, err
	}
	if !CanCreateInvite(membership.Role) {
		return empty, newError(CodeForbidden, "role cannot create invites")
	}
	if request.ExpiresInHours < 1 || request.ExpiresInHours > 720 || request.MaxUses < 1 || request.MaxUses > 20 {
		return empty, newError(CodeValidation, "invite expiry or max uses is invalid")
	}
	code, err := s.codes.NewCode()
	if err != nil {
		return empty, err
	}
	id, err := s.ids.NewID()
	if err != nil {
		return empty, err
	}
	now := s.clock.Now()
	invite := Invite{ID: id, FamilyID: familyID, CodeHash: s.inviteHash.Hash(code), ExpiresAt: now.Add(time.Duration(request.ExpiresInHours) * time.Hour), MaxUses: request.MaxUses, CreatedBy: userID, CreatedAt: now}
	if err := s.invites.Create(ctx, invite); err != nil {
		return empty, err
	}
	return InviteResponse{InviteID: invite.ID, Code: code, ExpiresAt: invite.ExpiresAt.UTC(), RemainingUses: invite.RemainingUses()}, nil
}

func (s *Service) Join(ctx context.Context, userID string, request JoinFamilyRequest) (FamilyResponse, error) {
	var empty FamilyResponse
	if strings.TrimSpace(userID) == "" {
		return empty, newError(CodeUnauthorized, "user is required")
	}
	code := strings.TrimSpace(request.Code)
	if utf8.RuneCountInString(code) < 8 || utf8.RuneCountInString(code) > 128 {
		return empty, newError(CodeValidation, "invite code is invalid")
	}
	now := s.clock.Now()
	invite, err := s.invites.FindByHash(ctx, s.inviteHash.Hash(code))
	if err != nil {
		return empty, newError(CodeInviteInvalid, "invite code is invalid")
	}
	if !invite.ExpiresAt.After(now) {
		return empty, newError(CodeInviteExpired, "invite code has expired")
	}
	if invite.RemainingUses() <= 0 {
		return empty, newError(CodeInviteExhausted, "invite code has no remaining uses")
	}
	if existing, findErr := s.memberships.Find(ctx, invite.FamilyID, userID); findErr == nil && existing.UserID != "" {
		family, familyErr := s.families.FindByID(ctx, invite.FamilyID)
		if familyErr != nil {
			return empty, familyErr
		}
		return FamilyResponse{Family: family, Membership: existing}, nil
	}
	family, membership, err := s.joiner.JoinWithInvite(ctx, invite.CodeHash, userID, now)
	if err != nil {
		if hasCode(err, CodeInviteExpired) || hasCode(err, CodeInviteExhausted) || hasCode(err, CodeAlreadyMember) {
			return empty, err
		}
		return empty, newError(CodeInviteInvalid, "invite code is invalid")
	}
	if err := s.families.SetCurrentForUser(ctx, userID, family.ID); err != nil {
		return empty, err
	}
	return FamilyResponse{Family: family, Membership: membership}, nil
}

func (s *Service) ListMembers(ctx context.Context, userID, familyID string) (MembersResponse, error) {
	membership, err := s.requireMembership(ctx, familyID, userID)
	if err != nil {
		return MembersResponse{}, err
	}
	if !CanViewFamily(membership.Role) {
		return MembersResponse{}, newError(CodeForbidden, "role cannot view family members")
	}
	members, err := s.memberships.List(ctx, familyID)
	if err != nil {
		return MembersResponse{}, err
	}
	return MembersResponse{Members: members}, nil
}

func (s *Service) requireMembership(ctx context.Context, familyID, userID string) (Membership, error) {
	if strings.TrimSpace(familyID) == "" || strings.TrimSpace(userID) == "" {
		return Membership{}, newError(CodeUnauthorized, "family and user are required")
	}
	membership, err := s.memberships.Find(ctx, familyID, userID)
	if err != nil || membership.UserID == "" {
		return Membership{}, newError(CodeForbidden, "user is not a family member")
	}
	return membership, nil
}

func CanViewFamily(role Role) bool {
	return role == RoleOwner || role == RoleAdmin || role == RoleMember
}
func CanCreateInvite(role Role) bool { return role == RoleOwner || role == RoleAdmin }
func CanRemoveMember(role Role) bool { return role == RoleOwner || role == RoleAdmin }
func CanRenameFamily(role Role) bool { return role == RoleOwner }
