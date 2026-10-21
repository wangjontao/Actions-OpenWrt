package main

import (
	"context"
	"fmt"
	"github.com/daeuniverse/outbound/dialer"
	_ "github.com/daeuniverse/outbound/dialer/http"
	_ "github.com/daeuniverse/outbound/dialer/hysteria2"
	_ "github.com/daeuniverse/outbound/dialer/shadowsocks"
	_ "github.com/daeuniverse/outbound/dialer/socks"
	_ "github.com/daeuniverse/outbound/dialer/trojan"
	_ "github.com/daeuniverse/outbound/dialer/tuic"
	_ "github.com/daeuniverse/outbound/dialer/v2ray"
	"github.com/daeuniverse/outbound/netproxy"
	_ "github.com/daeuniverse/outbound/protocol/shadowsocks"
	_ "github.com/daeuniverse/outbound/protocol/trojanc"
	_ "github.com/daeuniverse/outbound/protocol/tuic"
	_ "github.com/daeuniverse/outbound/protocol/vless"
	_ "github.com/daeuniverse/outbound/protocol/vmess"
	"net"
	"strconv"
	"strings"
	"time"
)

// Endpoint names resolve only through this relay's pinned direct DoH path.
// No OS DNS fallback, and no second transparent proxy core.
type encryptedBase struct{}

func (encryptedBase) DialContext(ctx context.Context, network, address string) (netproxy.Conn, error) {
	return dialBase(ctx, network, address, false)
}
func dialBase(ctx context.Context, network, address string, priority bool) (netproxy.Conn, error) {
	mn, err := netproxy.ParseMagicNetwork(network)
	if err != nil {
		return nil, err
	}
	network = mn.Network
	if mn.IPVersion != "" && (network == "tcp" || network == "udp") {
		network += mn.IPVersion
	}
	resolver := &net.Resolver{PreferGo: true, StrictErrors: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		d := net.Dialer{Timeout: 5 * time.Second}
		return d.DialContext(ctx, network, "127.0.0.1:12553")
	}}
	d := net.Dialer{Timeout: 5 * time.Second, Resolver: resolver}
	if priority {
		d.Control = priorityControl
	}
	c, e := d.DialContext(ctx, network, address)
	if e != nil {
		return nil, e
	}
	if u, ok := c.(*net.UDPConn); ok {
		return &pinnedUDPConn{u, address}, nil
	}
	return c, nil
}
func makeExits(cfg Config) (map[int]netproxy.Dialer, error) {
	return makeExitsBase(cfg, encryptedBase{})
}
func makeExitsBase(cfg Config, base netproxy.Dialer) (map[int]netproxy.Dialer, error) {
	result := map[int]netproxy.Dialer{}
	for key, link := range cfg.Exits {
		id, e := strconv.Atoi(key)
		if e != nil || id < 12600 || id >= 14000 || strings.ContainsAny(link, "\r\n\x00") {
			return nil, fmt.Errorf("invalid exit configuration")
		}
		d, _, e := dialer.NewNetproxyDialerFromLink(base, &dialer.ExtraOption{AllowInsecure: false}, link)
		if e != nil {
			return nil, fmt.Errorf("exit %d: unsupported or invalid node: %w", id, e)
		}
		result[id] = d
	}
	require := func(id int, where string) error {
		if id == 0 {
			return nil
		}
		if id < 12600 || id >= 14000 {
			return fmt.Errorf("%s references invalid exit", where)
		}
		if result[id] == nil {
			return fmt.Errorf("%s references missing exit", where)
		}
		return nil
	}
	for _, id := range cfg.Devices {
		if e := require(id, "device"); e != nil {
			return nil, e
		}
	}
	for _, p := range cfg.DevicePolicies {
		if e := require(p.Exit, "device DNS policy"); e != nil {
			return nil, e
		}
	}
	for _, p := range cfg.NetworkPolicies {
		if e := require(p.Exit, "network DNS policy"); e != nil {
			return nil, e
		}
	}
	if e := require(cfg.DefaultPolicy.Exit, "default DNS policy"); e != nil {
		return nil, e
	}
	return result, nil
}
func (r *relay) privateDial(ctx context.Context, id int, ip string) (net.Conn, error) {
	d := r.exits[id]
	if d == nil {
		return nil, fmt.Errorf("private DNS exit unavailable")
	}
	c, e := d.DialContext(ctx, "tcp", net.JoinHostPort(ip, "443"))
	if e != nil {
		return nil, e
	}
	return &netproxy.FakeNetConn{Conn: c, LAddr: &net.TCPAddr{}, RAddr: &net.TCPAddr{IP: net.ParseIP(ip), Port: 443}}, nil
}
