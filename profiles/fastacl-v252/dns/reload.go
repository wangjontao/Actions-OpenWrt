package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// Each query uses one immutable policy snapshot. Reload validates a replacement
// before publishing it; neither DNS listener nor existing TCP sessions restart.
type relayManager struct {
	current atomic.Pointer[relay]
	mu      sync.Mutex
	file    string
}

type reloadResult struct {
	OK       bool   `json:"ok"`
	Revision string `json:"revision,omitempty"`
	Error    string `json:"error,omitempty"`
}

func loadRelay(file string) (*relay, string, error) {
	b, err := os.ReadFile(file)
	if err != nil {
		return nil, "", err
	}
	var cfg Config
	if err = json.Unmarshal(b, &cfg); err != nil {
		return nil, "", err
	}
	if net.ParseIP(cfg.DirectIP).To4() == nil || net.ParseIP(cfg.PrivateIP).To4() == nil || cfg.DirectName == "" || cfg.PrivateName == "" {
		return nil, "", errors.New("invalid legacy DNS configuration")
	}
	for id, r := range cfg.Resolvers {
		if id == "" || net.ParseIP(r.IP).To4() == nil || (r.Type != "doh" && r.Type != "udp") || (r.Type == "doh" && r.Name == "") {
			return nil, "", errors.New("invalid DNS resolver")
		}
		if r.Type == "udp" && r.Port != 0 && r.Port != 53 {
			return nil, "", errors.New("invalid UDP DNS port")
		}
	}
	checkPolicy := func(p PolicyConfig) error {
		if err := validPolicy(cfg, p); err != nil {
			return err
		}
		if p.Exit != 0 && cfg.Resolvers[p.Resolver].Type != "doh" {
			return errors.New("proxy DNS requires DoH")
		}
		return nil
	}
	if cfg.DefaultPolicy.Resolver != "" {
		if err := checkPolicy(cfg.DefaultPolicy); err != nil {
			return nil, "", err
		}
	}
	for ip, p := range cfg.DevicePolicies {
		if net.ParseIP(ip).To4() == nil {
			return nil, "", errors.New("invalid device DNS address")
		}
		if err := checkPolicy(p); err != nil {
			return nil, "", err
		}
	}
	for cidr, p := range cfg.NetworkPolicies {
		if _, _, err := net.ParseCIDR(cidr); err != nil {
			return nil, "", errors.New("invalid DNS network")
		}
		if err := checkPolicy(p); err != nil {
			return nil, "", err
		}
	}
	exits, err := makeExits(cfg)
	if err != nil {
		return nil, "", err
	}
	r := &relay{config: cfg, exits: exits, clients: map[int]*http.Client{}, namedClients: map[string]*http.Client{}, cache: map[string]entry{}, slots: make(chan struct{}, 64)}
	sum := sha256.Sum256(b)
	return r, hex.EncodeToString(sum[:]), nil
}

func (r *relay) closeIdle() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, client := range r.clients {
		client.CloseIdleConnections()
	}
	for _, client := range r.namedClients {
		client.CloseIdleConnections()
	}
}

func (m *relayManager) reload() reloadResult {
	m.mu.Lock()
	defer m.mu.Unlock()
	next, revision, err := loadRelay(m.file)
	if err != nil {
		return reloadResult{Error: err.Error()}
	}
	old := m.current.Load()
	if old != nil && next.config.Listen != old.config.Listen {
		return reloadResult{Error: "DNS listen address change requires cold apply"}
	}
	m.current.Store(next)
	if old != nil {
		old.closeIdle()
	}
	return reloadResult{OK: true, Revision: revision}
}

func (m *relayManager) tcp(c net.Conn) {
	defer c.Close()
	ip, _, _ := net.SplitHostPort(c.RemoteAddr().String())
	for {
		c.SetDeadline(time.Now().Add(12 * time.Second))
		h := make([]byte, 2)
		if _, err := io.ReadFull(c, h); err != nil {
			return
		}
		q := make([]byte, int(binary.BigEndian.Uint16(h)))
		if _, err := io.ReadFull(c, q); err != nil {
			return
		}
		b := m.current.Load().resolve(q, ip)
		if b == nil {
			return
		}
		binary.BigEndian.PutUint16(h, uint16(len(b)))
		if _, err := c.Write(append(h, b...)); err != nil {
			return
		}
	}
}

func (m *relayManager) serveControl() (net.Listener, error) {
	path := m.file + ".sock"
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0600); err != nil {
		l.Close()
		return nil, err
	}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			// Serialize control work. Untrusted clients cannot access the
			// root-only socket and each request has a bounded read deadline.
			func() {
				defer c.Close()
				c.SetDeadline(time.Now().Add(5 * time.Second))
				command, err := bufio.NewReader(io.LimitReader(c, 32)).ReadString('\n')
				if err != nil || command != "reload\n" {
					json.NewEncoder(c).Encode(reloadResult{Error: "invalid control command"})
					return
				}
				json.NewEncoder(c).Encode(m.reload())
			}()
		}
	}()
	return l, nil
}

func requestReload(file string) error {
	c, err := net.DialTimeout("unix", file+".sock", time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.WriteString(c, "reload\n"); err != nil {
		return err
	}
	var result reloadResult
	if err := json.NewDecoder(io.LimitReader(c, 8192)).Decode(&result); err != nil {
		return err
	}
	if !result.OK {
		return fmt.Errorf("DNS reload rejected: %s", result.Error)
	}
	b, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(b)
	if hex.EncodeToString(sum[:]) != result.Revision {
		return errors.New("DNS configuration changed during reload")
	}
	fmt.Println("DNS configuration reloaded", result.Revision)
	return nil
}
