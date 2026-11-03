package processing

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestNormalizeImageRejectsInvalidAndStripsMetadata(t *testing.T) {
	for _, raw := range [][]byte{nil, []byte("not an image"), make([]byte, MaxImageBytes+1)} {
		if _, err := NormalizeImage(raw); err == nil {
			t.Fatal("invalid image accepted")
		}
	}
	img := image.NewRGBA(image.Rect(0, 0, 8, 12))
	img.Set(1, 1, color.White)
	var input bytes.Buffer
	if err := png.Encode(&input, img); err != nil {
		t.Fatal(err)
	}
	output, err := NormalizeImage(input.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(output))
	if err != nil || config.Width != 8 || config.Height != 12 {
		t.Fatalf("bad normalized output: %#v %v", config, err)
	}
}

func TestOrientationUsesViewWithoutFullImageCopy(t *testing.T) {
	src := image.NewNRGBA64(image.Rect(0, 0, 3, 2))
	for y := 0; y < 2; y++ {
		for x := 0; x < 3; x++ {
			src.Set(x, y, color.NRGBA64{R: uint16(100 * x), G: uint16(100 * y), A: 65535})
		}
	}
	view := orientImage(src, 6)
	if _, ok := view.(orientedImage); !ok {
		t.Fatal("orientation allocated full image")
	}
	if view.Bounds().Dx() != 2 || view.Bounds().Dy() != 3 {
		t.Fatal("orientation bounds")
	}
	for y := 0; y < 3; y++ {
		for x := 0; x < 2; x++ {
			if view.At(x, y) != src.At(y, 1-x) {
				t.Fatal("orientation pixel mismatch")
			}
		}
	}
}

func TestAIUnknownProviderOutcomeDoesNotAutomaticallyFailOver(t *testing.T) {
	calls := 0
	c := AIConfig{Endpoints: []AIEndpoint{{Endpoint: "http://one.test/v1", Model: "model", Protocol: "chat"}, {Endpoint: "http://two.test/v1", Model: "model", Protocol: "chat"}}, Client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { calls++; return nil, context.DeadlineExceeded })}}
	if _, err := c.call(context.Background(), AIRequest{User: "text"}); err != ErrOutcomeUnknown || calls != 1 {
		t.Fatalf("automatic duplicate inference: calls=%d err=%v", calls, err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestAIUsesOnlyOperatorDestinationAndExtractsText(t *testing.T) {
	for _, protocol := range []string{"chat", "responses"} {
		t.Run(protocol, func(t *testing.T) {
			calls := 0
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.Host != "operator.local" || r.Header.Get("Authorization") != "Bearer server-secret" {
					t.Fatal("destination/key changed")
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				if body["tools"] != nil || body["model"] != "server-model" {
					t.Fatal("model/tools not constrained")
				}
				response := `{"choices":[{"message":{"content":[{"type":"text","text":"draft"}]}}],"usage":{"total_tokens":3}}`
				if protocol == "responses" {
					response = `{"output":[{"type":"reasoning","content":[{"type":"output_text","text":"secret reasoning"}]},{"type":"message","content":[{"type":"output_text","text":"draft"}]}]}`
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(response))}, nil
			})}
			c := AIConfig{Client: client, Endpoints: []AIEndpoint{{Endpoint: "http://operator.local/v1", Key: "server-secret", Model: "server-model", Protocol: protocol, Level: "primary"}}}
			result, err := c.call(context.Background(), AIRequest{System: "contract", User: "untrusted OCR"})
			if err != nil || result.Content != "draft" || result.Model != "server-model" || result.Protocol != protocol || calls != 1 {
				t.Fatalf("bad AI response: %#v %v calls=%d", result, err, calls)
			}
		})
	}
}
func TestAIEnvRejectsCredentialsQueriesAndUnknownProtocol(t *testing.T) {
	for _, endpoint := range []string{"https://user:pass@example.test/v1", "https://example.test/v1?api_key=secret", "file:///etc/passwd"} {
		t.Setenv("AI_ENDPOINT", endpoint)
		t.Setenv("AI_MODEL", "model")
		if len(AIFromEnv().Endpoints) != 0 {
			t.Fatal("invalid provider enabled")
		}
	}
}

func TestCameraEXIFOrientationIsAppliedBeforeMetadataRemoval(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 8, 12))
	var encoded bytes.Buffer
	if err := jpeg.Encode(&encoded, img, nil); err != nil {
		t.Fatal(err)
	}
	// One little-endian TIFF orientation tag (rotate 90 degrees clockwise).
	exif := []byte{'E', 'x', 'i', 'f', 0, 0, 'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0}
	raw := append([]byte{0xff, 0xd8, 0xff, 0xe1, 0, byte(len(exif) + 2)}, exif...)
	raw = append(raw, encoded.Bytes()[2:]...)
	if jpegOrientation(raw) != 6 {
		t.Fatal("orientation tag not parsed")
	}
	output, err := NormalizeImage(raw)
	if err != nil {
		t.Fatal(err)
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(output))
	if err != nil || config.Width != 12 || config.Height != 8 {
		t.Fatalf("camera orientation lost: %#v %v", config, err)
	}
	if bytes.Contains(output, []byte("Exif")) {
		t.Fatal("EXIF retained")
	}
}
