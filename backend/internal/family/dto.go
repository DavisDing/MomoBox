package family

import "time"

type CreateFamilyRequest struct {
	Name string `json:"name"`
}

type FamilyResponse struct {
	Family     Family     `json:"family"`
	Membership Membership `json:"membership"`
}

type CreateInviteRequest struct {
	ExpiresInHours int `json:"expires_in_hours"`
	MaxUses        int `json:"max_uses"`
}

type InviteResponse struct {
	InviteID      string    `json:"invite_id"`
	Code          string    `json:"code"`
	ExpiresAt     time.Time `json:"expires_at"`
	RemainingUses int       `json:"remaining_uses"`
}

type JoinFamilyRequest struct {
	Code string `json:"code"`
}

type MembersResponse struct {
	Members []FamilyMember `json:"members"`
}
