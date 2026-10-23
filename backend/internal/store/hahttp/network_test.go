package hahttp

import (
	"context"
	"errors"
	"net"
	"testing"
)

func TestDialPinsValidatedAddressAndPreservesLAN(t *testing.T) {
	lookups := 0
	dialed := ""
	_, err := dialValidated(context.Background(), "tcp", "ha.local:8123", func(context.Context, string) ([]net.IPAddr, error) {
		lookups++
		return []net.IPAddr{{IP: net.ParseIP("192.168.1.20")}}, nil
	}, func(_ context.Context, _ string, address string) (net.Conn, error) { dialed = address; return nil, nil })
	if err != nil || lookups != 1 || dialed != "192.168.1.20:8123" {
		t.Fatalf("target not pinned to validated LAN address: %q %d %v", dialed, lookups, err)
	}
}
func TestDialRejectsMetadataBeforeConnecting(t *testing.T) {
	for _, address := range []string{"169.254.169.254", "169.254.170.2", "100.100.100.200", "fd00:ec2::254", "::ffff:169.254.169.254", "0.0.0.0", "ff02::1"} {
		called := false
		_, err := dialValidated(context.Background(), "tcp", "ha.local:8123", func(context.Context, string) ([]net.IPAddr, error) {
			return []net.IPAddr{{IP: net.ParseIP("192.168.1.20")}, {IP: net.ParseIP(address)}}, nil
		}, func(context.Context, string, string) (net.Conn, error) {
			called = true
			return nil, errors.New("must not connect")
		})
		if err == nil || called {
			t.Fatalf("prohibited resolved address %q was dialed", address)
		}
	}
}
