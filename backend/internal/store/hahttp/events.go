package hahttp

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/momobox/backend/internal/homeassistant"
)

type triggerState struct {
	EntityID    string    `json:"entity_id"`
	State       string    `json:"state"`
	LastChanged time.Time `json:"last_changed"`
}

type eventMessage struct {
	ID      int    `json:"id"`
	Type    string `json:"type"`
	Success bool   `json:"success"`
	Event   struct {
		Variables struct {
			Trigger struct {
				EntityID string        `json:"entity_id"`
				From     *triggerState `json:"from_state"`
				To       *triggerState `json:"to_state"`
			} `json:"trigger"`
		} `json:"variables"`
	} `json:"event"`
}

func (m eventMessage) transition() (homeassistant.StateTransition, bool) {
	trigger := m.Event.Variables.Trigger
	if m.Type != "event" || m.ID != 1 || trigger.EntityID == "" ||
		trigger.From == nil || trigger.To == nil ||
		trigger.From.EntityID != trigger.EntityID || trigger.To.EntityID != trigger.EntityID {
		return homeassistant.StateTransition{}, false
	}
	return homeassistant.StateTransition{
		EntityID: trigger.EntityID, From: trigger.From.State, To: trigger.To.State,
		ChangedFrom: trigger.From.LastChanged, ChangedAt: trigger.To.LastChanged,
	}, true
}

func (c *Client) SubscribeStateChanges(ctx context.Context, baseURL, token string, entityIDs []string, receive func(homeassistant.StateTransition)) error {
	if len(entityIDs) == 0 {
		return errors.New("HA subscription requires selected entities")
	}
	for _, id := range entityIDs {
		if _, ok := entityDomain(id); !ok {
			return errors.New("invalid HA subscription entity")
		}
	}
	conn, err := c.connectStateTrigger(ctx, baseURL, token, entityIDs)
	if err != nil {
		return err
	}
	defer conn.CloseNow()
	streamCtx, stop := context.WithCancel(ctx)
	defer stop()
	go keepEventStreamAlive(streamCtx, stop, conn)

	selected := make(map[string]bool, len(entityIDs))
	for _, id := range entityIDs {
		selected[id] = true
	}
	for {
		var message eventMessage
		if err := wsjson.Read(streamCtx, conn, &message); err != nil {
			return err
		}
		if change, ok := message.transition(); ok && selected[change.EntityID] {
			receive(change)
		}
	}
}

func (c *Client) connectStateTrigger(ctx context.Context, baseURL, token string, entityIDs []string) (*websocket.Conn, error) {
	if err := homeassistant.ValidateBaseURL(baseURL); err != nil {
		return nil, err
	}
	if err := homeassistant.ValidateAccessToken(token); err != nil {
		return nil, err
	}
	endpoint, err := url.JoinPath(homeassistant.NormalizeBaseURL(baseURL), "api", "websocket")
	if err != nil {
		return nil, errors.New("build HA event endpoint")
	}
	// An http(s) URL lets the same guarded transport handle DNS, TLS and
	// redirect protection as the REST client.
	handshake, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()
	client := *c.httpClient
	client.Timeout = 0
	conn, _, err := websocket.Dial(handshake, endpoint, &websocket.DialOptions{HTTPClient: &client})
	if err != nil {
		return nil, errors.New("connect HA event endpoint")
	}
	conn.SetReadLimit(c.maxResponseBytes)
	if err := authenticateStateTrigger(handshake, conn, strings.TrimSpace(token), entityIDs); err != nil {
		conn.CloseNow()
		return nil, err
	}
	return conn, nil
}

func authenticateStateTrigger(ctx context.Context, conn *websocket.Conn, token string, entities []string) error {
	var message eventMessage
	if err := wsjson.Read(ctx, conn, &message); err != nil || message.Type != "auth_required" {
		return errors.New("HA event endpoint did not request authentication")
	}
	if err := wsjson.Write(ctx, conn, map[string]string{"type": "auth", "access_token": token}); err != nil {
		return errors.New("send HA event authentication")
	}
	if err := wsjson.Read(ctx, conn, &message); err != nil || message.Type != "auth_ok" {
		return errors.New("HA event authentication failed")
	}
	command := map[string]any{
		"id": 1, "type": "subscribe_trigger",
		"trigger": map[string]any{"platform": "state", "entity_id": entities, "to": nil},
	}
	if err := wsjson.Write(ctx, conn, command); err != nil {
		return errors.New("send HA state trigger subscription")
	}
	message = eventMessage{}
	if err := wsjson.Read(ctx, conn, &message); err != nil || message.ID != 1 || message.Type != "result" || !message.Success {
		return errors.New("HA state trigger subscription was rejected")
	}
	return nil
}

func keepEventStreamAlive(ctx context.Context, stop context.CancelFunc, conn *websocket.Conn) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
			err := conn.Ping(pingCtx)
			cancel()
			if err != nil {
				stop()
				return
			}
		}
	}
}

func (c *Client) NotifyCompanion(ctx context.Context, baseURL, token, action, title, message string) error {
	domain, ok := entityDomain(action)
	if !ok || domain != "notify" || !strings.HasPrefix(action, "notify.mobile_app_") || action == "notify.mobile_app_" {
		return errors.New("invalid HA Companion notification action")
	}
	status, err := c.request(ctx, http.MethodPost, baseURL, token,
		[]string{"api", "services", "notify", strings.TrimPrefix(action, "notify.")},
		map[string]string{"title": title, "message": message}, nil)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return statusError(status)
	}
	return nil
}
