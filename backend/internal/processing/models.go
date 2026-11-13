package processing

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type AIModel struct {
	ID      string `json:"id"`
	Default bool   `json:"default"`
}

func validModel(id string) bool {
	return id != "" && len(id) <= 256 && strings.TrimSpace(id) == id && !strings.ContainsAny(id, "\r\n\x00")
}

// ModelCatalogError contains only bounded diagnostic fields, never upstream
// response text, credentials, URLs or wrapped transport errors.
type ModelCatalogError struct {
	Code           string
	UpstreamStatus int
}

func (e *ModelCatalogError) Error() string { return e.Code }
func (e *ModelCatalogError) Unwrap() error { return ErrUnavailable }

func catalogError(code string, status int) *ModelCatalogError {
	return &ModelCatalogError{Code: code, UpstreamStatus: status}
}

// Preserve operator proxy prefixes. Only a definitive route miss permits the
// alternative versioned/unversioned GET; inference is never probed here.
func modelCatalogURLs(endpoint string) ([]string, error) {
	target := strings.TrimRight(strings.TrimSpace(endpoint), "/")
	u, err := url.Parse(target)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || (u.Scheme != "http" && u.Scheme != "https") {
		return nil, catalogError("AI_NOT_CONFIGURED", 0)
	}
	for _, suffix := range []string{"/chat/completions", "/responses"} {
		target = strings.TrimSuffix(target, suffix)
	}
	base := strings.TrimSuffix(target, "/models")
	primary := target
	if !strings.HasSuffix(target, "/models") {
		if u.Path == "" || u.Path == "/" {
			base += "/v1"
		}
		primary = base + "/models"
	}
	alternative := base + "/v1/models"
	if strings.HasSuffix(base, "/v1") {
		alternative = strings.TrimSuffix(base, "/v1") + "/models"
	}
	return []string{primary, alternative}, nil
}

func (c AIConfig) discoverModels(ctx context.Context, endpoint AIEndpoint) ([]string, error) {
	targets, err := modelCatalogURLs(endpoint.Endpoint)
	if err != nil {
		return nil, err
	}
	requestCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	client := http.Client{Timeout: 10 * time.Second}
	if c.Client != nil {
		client = *c.Client
	}
	// Do not let an operator key follow a redirect, even with an injected client.
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	for i, target := range targets {
		req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, target, nil)
		if err != nil {
			return nil, catalogError("AI_NOT_CONFIGURED", 0)
		}
		if key := strings.TrimSpace(endpoint.Key); key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		req.Header.Set("Accept", "application/json")
		response, err := client.Do(req)
		if err != nil {
			var networkError net.Error
			if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &networkError) && networkError.Timeout()) {
				return nil, catalogError("AI_MODELS_TIMEOUT", 0)
			}
			return nil, catalogError("AI_MODELS_UNREACHABLE", 0)
		}
		status := response.StatusCode
		if status != http.StatusOK {
			response.Body.Close()
			switch {
			case status == 401 || status == 403:
				return nil, catalogError("AI_MODELS_AUTH_FAILED", status)
			case status == 404 || status == 405:
				if i == 0 {
					continue
				}
				return nil, catalogError("AI_MODELS_NOT_FOUND", status)
			case status >= 300 && status < 400:
				return nil, catalogError("AI_MODELS_REDIRECT", status)
			default:
				return nil, catalogError("AI_MODELS_UPSTREAM_FAILED", status)
			}
		}
		raw, readErr := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
		response.Body.Close()
		if errors.Is(requestCtx.Err(), context.DeadlineExceeded) || errors.Is(readErr, context.DeadlineExceeded) {
			return nil, catalogError("AI_MODELS_TIMEOUT", status)
		}
		var payload struct {
			Data json.RawMessage `json:"data"`
		}
		var models []struct {
			ID string `json:"id"`
		}
		if readErr != nil || len(raw) > 1<<20 || json.Unmarshal(raw, &payload) != nil || len(payload.Data) == 0 || string(payload.Data) == "null" || json.Unmarshal(payload.Data, &models) != nil {
			return nil, catalogError("AI_MODELS_INVALID_RESPONSE", status)
		}
		ids := []string{}
		for _, model := range models {
			if validModel(model.ID) {
				ids = append(ids, model.ID)
			}
		}
		if len(ids) == 0 {
			return nil, catalogError("AI_MODELS_EMPTY", status)
		}
		return ids, nil
	}
	return nil, catalogError("AI_MODELS_NOT_FOUND", 404)
}

// Only the server's gateway and credential are used. Model IDs are the only
// upstream fields returned; endpoints, keys and provider metadata stay here.
func (c AIConfig) Models(ctx context.Context) ([]AIModel, error) {
	if len(c.Endpoints) == 0 {
		return nil, catalogError("AI_NOT_CONFIGURED", 0)
	}
	ids := []string{}
	var discoveryError error
	if len(c.AllowedModels) > 0 {
		ids = append(ids, c.AllowedModels...)
	} else {
		ids, discoveryError = c.discoverModels(ctx, c.Endpoints[0])
		// Fixed deployments remain compatible with providers without discovery.
		for _, endpoint := range c.Endpoints {
			if validModel(endpoint.Model) {
				ids = append(ids, endpoint.Model)
			}
		}
	}
	seen := map[string]bool{}
	models := []AIModel{}
	for _, id := range ids {
		if validModel(id) && !seen[id] && len(models) < 500 {
			seen[id] = true
			models = append(models, AIModel{ID: id, Default: id == c.Endpoints[0].Model})
		}
	}
	if len(models) == 0 {
		if discoveryError != nil {
			return nil, discoveryError
		}
		return nil, catalogError("AI_MODELS_EMPTY", 0)
	}
	if c.Endpoints[0].Model == "" || !seen[c.Endpoints[0].Model] {
		models[0].Default = true
	}
	return models, nil
}

func (c AIConfig) selectModel(ctx context.Context, selected string) (AIConfig, error) {
	if len(c.Endpoints) == 0 {
		return c, ErrUnavailable
	}
	if selected == "" && c.Endpoints[0].Model != "" && len(c.AllowedModels) == 0 {
		return c, nil
	}
	if selected != "" && !validModel(selected) {
		return c, ErrInvalid
	}
	models, err := c.Models(ctx)
	if err != nil {
		return c, err
	}
	if selected == "" {
		for _, model := range models {
			if model.Default {
				selected = model.ID
				break
			}
		}
	}
	allowed := false
	for _, model := range models {
		if model.ID == selected {
			allowed = true
			break
		}
	}
	if !allowed {
		return c, ErrInvalid
	}
	endpoint := c.Endpoints[0]
	for _, configured := range c.Endpoints {
		if configured.Model == selected {
			endpoint = configured
			break
		}
	}
	endpoint.Model = selected
	c.Endpoints = []AIEndpoint{endpoint}
	return c, nil
}
