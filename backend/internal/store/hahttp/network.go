package hahttp

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strings"
	"time"
)

// Explicit cloud metadata targets cannot be HA servers. Private LAN, local
// DNS and loopback deployments remain supported.
func forbiddenAddress(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if ip.IsUnspecified() || ip.IsMulticast() {
		return true
	}
	for _, raw := range []string{"169.254.169.254", "169.254.170.2", "100.100.100.200", "fd00:ec2::254"} {
		if ip.Equal(net.ParseIP(raw)) {
			return true
		}
	}
	return false
}

func guardedTransport(original *http.Transport) *http.Transport {
	transport := original.Clone()
	// A proxy could resolve a different target and bypass the NAS-side address
	// checks. HA is reached directly at the explicitly configured endpoint.
	transport.Proxy = nil
	transport.DialTLS = nil
	transport.DialTLSContext = nil
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		return dialValidated(ctx, network, address, net.DefaultResolver.LookupIPAddr, (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext)
	}
	return transport
}

type ipLookup func(context.Context, string) ([]net.IPAddr, error)
type addressDial func(context.Context, string, string) (net.Conn, error)

func dialValidated(ctx context.Context, network, address string, lookup ipLookup, dial addressDial) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, errors.New("invalid Home Assistant address")
	}
	canonical := strings.TrimSuffix(strings.ToLower(host), ".")
	for _, blocked := range []string{"metadata.google.internal", "metadata.goog", "instance-data.ec2.internal"} {
		if canonical == blocked {
			return nil, errors.New("Home Assistant metadata target is prohibited")
		}
	}
	addresses, err := lookup(ctx, host)
	if err != nil {
		return nil, errors.New("resolve Home Assistant host")
	}
	if len(addresses) == 0 {
		return nil, errors.New("Home Assistant host has no addresses")
	}
	for _, value := range addresses {
		if forbiddenAddress(value.IP) {
			return nil, errors.New("Home Assistant resolved to a prohibited address")
		}
	}
	// Dial the already checked address, never the hostname, so a second DNS
	// lookup cannot change the peer between validation and connection.
	for _, value := range addresses {
		ip := value.IP.String()
		if value.Zone != "" {
			ip += "%" + value.Zone
		}
		conn, dialErr := dial(ctx, network, net.JoinHostPort(ip, port))
		if dialErr == nil {
			return conn, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return nil, errors.New("connect Home Assistant host")
}
