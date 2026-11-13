package processing

import (
	"context"
	"encoding/json"
	"io"
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

// Only the server's gateway and credential are used. Model IDs are the only
// upstream fields returned; endpoints, keys and provider metadata stay here.
func (c AIConfig) Models(ctx context.Context) ([]AIModel, error) {
	if len(c.Endpoints) == 0 {
		return nil, ErrUnavailable
	}
	ids := []string{}
	if len(c.AllowedModels) > 0 {
		ids = append(ids, c.AllowedModels...)
	} else {
		endpoint := c.Endpoints[0]
		target := strings.TrimRight(endpoint.Endpoint, "/")
		for _, suffix := range []string{"/chat/completions", "/responses"} {
			target = strings.TrimSuffix(target, suffix)
		}
		u, err := url.Parse(target)
		if err != nil {
			return nil, ErrUnavailable
		}
		if u.Path == "" || u.Path == "/" {
			target += "/v1"
		}
		target += "/models"
		requestCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, target, nil)
		if err != nil {
			return nil, ErrUnavailable
		}
		if endpoint.Key != "" {
			req.Header.Set("Authorization", "Bearer "+endpoint.Key)
		}
		client := c.Client
		if client == nil {
			client = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		}
		response, err := client.Do(req)
		if err == nil {
			defer response.Body.Close()
			raw, readErr := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
			var payload struct {
				Data []struct {
					ID string `json:"id"`
				} `json:"data"`
			}
			if response.StatusCode == 200 && readErr == nil && len(raw) <= 1<<20 && json.Unmarshal(raw, &payload) == nil {
				for _, model := range payload.Data {
					if validModel(model.ID) {
						ids = append(ids, model.ID)
					}
				}
			}
		}
	}
	// Explicitly deployed model names remain usable when a provider has no
	// model-list endpoint. Explicit AI_MODELS constrains even configured models.
	if len(c.AllowedModels) == 0 {
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
		return nil, ErrUnavailable
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
