package homeassistant

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// ConsumableUnit is deliberately an integer-count unit. The first HA linkage
// release never performs ml/g/勺 conversion, so every recipe quantity is a
// positive count of pieces, capsules, tablets, loads, or cycles.
type ConsumableUnit string

const (
	UnitPiece   ConsumableUnit = "piece"
	UnitCapsule ConsumableUnit = "capsule"
	UnitTablet  ConsumableUnit = "tablet"
	UnitLoad    ConsumableUnit = "load"
	UnitCycle   ConsumableUnit = "cycle"
)

func (u ConsumableUnit) Valid() bool {
	switch u {
	case UnitPiece, UnitCapsule, UnitTablet, UnitLoad, UnitCycle:
		return true
	default:
		return false
	}
}

type ConsumableGroup struct {
	ID          string
	FamilyID    string
	Name        string
	Description string
	CreatedByUserID string
	Items       []ConsumableGroupItem
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

type ConsumableGroupItem struct {
	ID       string
	GroupID  string
	ProductID string
	Quantity int
	Unit     ConsumableUnit
}

type ConsumableRecipe struct {
	ID          string
	FamilyID    string
	Name        string
	Description string
	CreatedByUserID string
	Groups      []ConsumableRecipeGroup
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

type ConsumableRecipeGroup struct {
	ID       string
	RecipeID string
	GroupID  string
	Quantity int
	Unit     ConsumableUnit
}

type LinkageRule struct {
	ID                 string
	FamilyID           string
	Name               string
	IntegrationID      string
	EntityID           string
	ApplianceDomain    string
	StartState         string
	CompleteState      string
	RecipeID           string
	Enabled            bool
	RequiresConfirmation bool
	CreatedByUserID      string
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

type HAEvent struct {
	IntegrationID string
	EntityID       string
	ApplianceRunID string
	Domain         string
	State          string
	PreviousState  string
	OccurredAt     time.Time
	Attributes     map[string]any
}

type ApplianceRun struct {
	ID             string
	FamilyID       string
	RuleID         string
	ApplianceRunID string
	IntegrationID  string
	EntityID       string
	Domain         string
	Status         string
	StartedAt      *time.Time
	CompletedAt    *time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type PurchaseSuggestion struct {
	ProductID string
	ProductName string
	Quantity  int
	Unit      ConsumableUnit
}

type LinkageSuggestionStatus string

const (
	SuggestionPending           LinkageSuggestionStatus = "pending"
	SuggestionDeducted          LinkageSuggestionStatus = "deducted"
	SuggestionIgnored           LinkageSuggestionStatus = "ignored"
	SuggestionInsufficientStock LinkageSuggestionStatus = "insufficient_stock"
)

type LinkageSuggestion struct {
	ID             string
	FamilyID       string
	RuleID         string
	RecipeID       string
	ApplianceRunID string
	Status         LinkageSuggestionStatus
	RequiresConfirmation bool
	PurchaseSuggestions []PurchaseSuggestion
	CreatedAt      time.Time
	ResolvedAt     *time.Time
	ResolvedBy     string
}

type LinkageAudit struct {
	ID             string
	FamilyID       string
	RuleID         string
	ApplianceRunID string
	SuggestionID   string
	Action         string
	ActorID        string
	Details        map[string]any
	CreatedAt      time.Time
}

type EventProcessResult struct {
	Run         *ApplianceRun
	Suggestion  *LinkageSuggestion
	Duplicate   bool
	AuditID     string
}

type SuggestionDecision string

const (
	DecisionConfirm SuggestionDecision = "confirm"
	DecisionIgnore  SuggestionDecision = "ignore"
)

// AutomationRepository is the persistence boundary for the HA consumable
// linkage feature. It intentionally does not depend on sync internals. The
// returned records carry stable IDs and status transitions that a later sync
// adapter can publish as ordinary family-scoped changes.
type AutomationRepository interface {
	ListConsumableGroups(context.Context, string) ([]ConsumableGroup, error)
	SaveConsumableGroup(context.Context, ConsumableGroup) (ConsumableGroup, error)
	ListConsumableRecipes(context.Context, string) ([]ConsumableRecipe, error)
	SaveConsumableRecipe(context.Context, ConsumableRecipe) (ConsumableRecipe, error)
	ListLinkageRules(context.Context, string) ([]LinkageRule, error)
	SaveLinkageRule(context.Context, LinkageRule) (LinkageRule, error)
	ListLinkageSuggestions(context.Context, string, LinkageSuggestionStatus) ([]LinkageSuggestion, error)
	ProcessEvent(context.Context, string, HAEvent, time.Time) (EventProcessResult, error)
	ResolveLinkageSuggestion(context.Context, string, string, SuggestionDecision, string, time.Time) (LinkageSuggestion, error)
}

// AutomationRepositoryProvider lets the existing composition root discover the
// optional phase-four repository without changing the sync service contract.
type AutomationRepositoryProvider interface {
	AutomationRepository() AutomationRepository
}

func (s *Service) automationRepository() (AutomationRepository, error) {
	if provider, ok := s.Integrations.(AutomationRepositoryProvider); ok {
		if repo := provider.AutomationRepository(); repo != nil {
			return repo, nil
		}
	}
	return nil, businessError(CodeNotConfigured, "Home Assistant consumable linkage is not configured", nil)
}

func (s *Service) ListConsumableGroups(ctx context.Context, actor Actor) ([]ConsumableGroup, error) {
	if err := validateActor(actor); err != nil { return nil, err }
	repo, err := s.automationRepository(); if err != nil { return nil, err }
	return repo.ListConsumableGroups(ctx, actor.FamilyID)
}

func (s *Service) SaveConsumableGroup(ctx context.Context, actor Actor, group ConsumableGroup) (ConsumableGroup, error) {
	if err := validateAutomationManager(actor); err != nil { return ConsumableGroup{}, err }
	if err := validateGroup(actor.FamilyID, group); err != nil { return ConsumableGroup{}, err }
	repo, err := s.automationRepository(); if err != nil { return ConsumableGroup{}, err }
	if group.ID == "" { group.ID = newID(); group.CreatedAt = s.now() }
	group.FamilyID = actor.FamilyID; group.CreatedByUserID = actor.UserID; group.UpdatedAt = s.now()
	return repo.SaveConsumableGroup(ctx, group)
}

func (s *Service) ListConsumableRecipes(ctx context.Context, actor Actor) ([]ConsumableRecipe, error) {
	if err := validateActor(actor); err != nil { return nil, err }
	repo, err := s.automationRepository(); if err != nil { return nil, err }
	return repo.ListConsumableRecipes(ctx, actor.FamilyID)
}

func (s *Service) SaveConsumableRecipe(ctx context.Context, actor Actor, recipe ConsumableRecipe) (ConsumableRecipe, error) {
	if err := validateAutomationManager(actor); err != nil { return ConsumableRecipe{}, err }
	if err := validateRecipe(actor.FamilyID, recipe); err != nil { return ConsumableRecipe{}, err }
	repo, err := s.automationRepository(); if err != nil { return ConsumableRecipe{}, err }
	if recipe.ID == "" { recipe.ID = newID(); recipe.CreatedAt = s.now() }
	recipe.FamilyID = actor.FamilyID; recipe.CreatedByUserID = actor.UserID; recipe.UpdatedAt = s.now()
	return repo.SaveConsumableRecipe(ctx, recipe)
}

func (s *Service) ListLinkageRules(ctx context.Context, actor Actor) ([]LinkageRule, error) {
	if err := validateActor(actor); err != nil { return nil, err }
	repo, err := s.automationRepository(); if err != nil { return nil, err }
	return repo.ListLinkageRules(ctx, actor.FamilyID)
}

func (s *Service) SaveLinkageRule(ctx context.Context, actor Actor, rule LinkageRule) (LinkageRule, error) {
	if err := validateAutomationManager(actor); err != nil { return LinkageRule{}, err }
	if err := validateRule(actor.FamilyID, rule); err != nil { return LinkageRule{}, err }
	repo, err := s.automationRepository(); if err != nil { return LinkageRule{}, err }
	if rule.ID == "" { rule.ID = newID(); rule.CreatedAt = s.now() }
	rule.FamilyID = actor.FamilyID; rule.CreatedByUserID = actor.UserID; rule.UpdatedAt = s.now()
	return repo.SaveLinkageRule(ctx, rule)
}

func (s *Service) ListLinkageSuggestions(ctx context.Context, actor Actor, status LinkageSuggestionStatus) ([]LinkageSuggestion, error) {
	if err := validateActor(actor); err != nil { return nil, err }
	repo, err := s.automationRepository(); if err != nil { return nil, err }
	return repo.ListLinkageSuggestions(ctx, actor.FamilyID, status)
}

func (s *Service) ProcessHAEvent(ctx context.Context, actor Actor, event HAEvent) (EventProcessResult, error) {
	if err := validateActor(actor); err != nil { return EventProcessResult{}, err }
	var err error
	event, err = NormalizeHAEvent(event)
	if err != nil { return EventProcessResult{}, businessError(CodeInvalidArgument, err.Error(), err) }
	repo, err := s.automationRepository(); if err != nil { return EventProcessResult{}, err }
	return repo.ProcessEvent(ctx, actor.FamilyID, event, s.now())
}

func (s *Service) ResolveLinkageSuggestion(ctx context.Context, actor Actor, suggestionID string, decision SuggestionDecision) (LinkageSuggestion, error) {
	if err := validateActor(actor); err != nil { return LinkageSuggestion{}, err }
	if actor.Role != RoleOwner && actor.Role != RoleAdmin && actor.Role != RoleMember { return LinkageSuggestion{}, businessError(CodeForbidden, "invalid family role", nil) }
	if strings.TrimSpace(suggestionID) == "" { return LinkageSuggestion{}, businessError(CodeInvalidArgument, "suggestion_id is required", nil) }
	if decision != DecisionConfirm && decision != DecisionIgnore { return LinkageSuggestion{}, businessError(CodeInvalidArgument, "decision must be confirm or ignore", nil) }
	repo, err := s.automationRepository(); if err != nil { return LinkageSuggestion{}, err }
	return repo.ResolveLinkageSuggestion(ctx, actor.FamilyID, suggestionID, decision, actor.UserID, s.now())
}

func validateAutomationManager(actor Actor) error {
	if err := validateActor(actor); err != nil { return err }
	if !actor.Role.CanManageIntegration() { return businessError(CodeForbidden, "only owner or admin can configure consumable linkage", nil) }
	return nil
}

func validateGroup(familyID string, group ConsumableGroup) error {
	if group.FamilyID != "" && group.FamilyID != familyID { return businessError(CodeForbidden, "group is outside the current family", nil) }
	if strings.TrimSpace(group.Name) == "" || len(strings.TrimSpace(group.Name)) > 120 { return businessError(CodeInvalidArgument, "group name is invalid", nil) }
	if len(group.Items) == 0 { return businessError(CodeInvalidArgument, "group must contain at least one product", nil) }
	for _, item := range group.Items { if strings.TrimSpace(item.ProductID) == "" || item.Quantity < 1 || !item.Unit.Valid() { return businessError(CodeInvalidArgument, "group item is invalid", nil) } }
	return nil
}

func validateRecipe(familyID string, recipe ConsumableRecipe) error {
	if recipe.FamilyID != "" && recipe.FamilyID != familyID { return businessError(CodeForbidden, "recipe is outside the current family", nil) }
	if strings.TrimSpace(recipe.Name) == "" || len(strings.TrimSpace(recipe.Name)) > 120 || len(recipe.Groups) == 0 { return businessError(CodeInvalidArgument, "recipe is invalid", nil) }
	for _, item := range recipe.Groups { if strings.TrimSpace(item.GroupID) == "" || item.Quantity < 1 || !item.Unit.Valid() { return businessError(CodeInvalidArgument, "recipe group is invalid", nil) } }
	return nil
}

func validateRule(familyID string, rule LinkageRule) error {
	if rule.FamilyID != "" && rule.FamilyID != familyID { return businessError(CodeForbidden, "rule is outside the current family", nil) }
	for key, value := range map[string]string{"name": rule.Name, "integration_id": rule.IntegrationID, "entity_id": rule.EntityID, "appliance_domain": rule.ApplianceDomain, "start_state": rule.StartState, "complete_state": rule.CompleteState, "recipe_id": rule.RecipeID} { if strings.TrimSpace(value) == "" { return businessError(CodeInvalidArgument, fmt.Sprintf("%s is required", key), nil) } }
	if _, err := NormalizeHAState(rule.StartState); err != nil { return businessError(CodeInvalidArgument, "start_state must be running/active/on", err) }
	if _, err := NormalizeHAState(rule.CompleteState); err != nil { return businessError(CodeInvalidArgument, "complete_state must be completed/complete/finished/off", err) }
	if !rule.RequiresConfirmation { return businessError(CodeInvalidArgument, "requires_confirmation must remain true in the first release", nil) }
	return nil
}

func validateEvent(event HAEvent) error {
	if _, err := NormalizeHAEvent(event); err != nil { return businessError(CodeInvalidArgument, err.Error(), err) }
	if event.OccurredAt.IsZero() { return businessError(CodeInvalidArgument, "occurred_at is required", nil) }
	return nil
}
