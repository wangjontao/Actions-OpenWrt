package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"flag"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func reloadConfig() Config {
	return Config{Listen: "127.0.0.1:12553", DirectIP: "223.5.5.5", DirectName: "dns.alidns.com", PrivateIP: "1.1.1.1", PrivateName: "cloudflare-dns.com"}
}

func writeConfig(t *testing.T, file string, cfg Config) {
	t.Helper()
	b, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, b, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestReloadRejectsInvalidConfigWithoutChangingPolicy(t *testing.T) {
	file := filepath.Join(t.TempDir(), "dns.json")
	cfg := reloadConfig()
	writeConfig(t, file, cfg)
	r, _, err := loadRelay(file)
	if err != nil {
		t.Fatal(err)
	}
	m := &relayManager{file: file}
	m.current.Store(r)
	if err := os.WriteFile(file, []byte(`{"exits":[]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if result := m.reload(); result.OK || result.Error == "" {
		t.Fatal("invalid reload accepted", result)
	}
	if m.current.Load() != r {
		t.Fatal("invalid reload changed the active policy")
	}
	cfg.Listen = "127.0.0.1:12554"
	writeConfig(t, file, cfg)
	if m.reload().OK || m.current.Load() != r {
		t.Fatal("hot reload changed DNS topology")
	}
	cfg.Listen = r.config.Listen
	cfg.DirectIP = "1.12.12.12"
	writeConfig(t, file, cfg)
	if result := m.reload(); !result.OK || result.Revision == "" {
		t.Fatal(result)
	}
	if m.current.Load() == r || m.current.Load().config.DirectIP != cfg.DirectIP {
		t.Fatal("new policy was not published")
	}
}

func snapshot(marker byte) *relay {
	client := &http.Client{Transport: roundFunc(func(req *http.Request) (*http.Response, error) {
		q, _ := io.ReadAll(req.Body)
		b := answer(q)
		b[len(b)-1] = marker
		return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(b))}, nil
	})}
	return &relay{config: Config{DefaultPolicy: PolicyConfig{Resolver: "test"}, Resolvers: map[string]ResolverConfig{"test": {Type: "doh", IP: "1.1.1.1", Name: "test.example"}}}, namedClients: map[string]*http.Client{"test@0": client}, cache: map[string]entry{}, slots: make(chan struct{}, 64)}
}

func TestExistingTCPSessionUsesNewPolicyOnNextQuery(t *testing.T) {
	m := &relayManager{}
	m.current.Store(snapshot(11))
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan struct{})
	go func() { defer close(done); m.tcp(server) }()
	request := func(want byte) {
		t.Helper()
		client.SetDeadline(time.Now().Add(time.Second))
		q := query()
		h := make([]byte, 2)
		binary.BigEndian.PutUint16(h, uint16(len(q)))
		if _, err := client.Write(append(h, q...)); err != nil {
			t.Fatal(err)
		}
		if _, err := io.ReadFull(client, h); err != nil {
			t.Fatal(err)
		}
		b := make([]byte, int(binary.BigEndian.Uint16(h)))
		if _, err := io.ReadFull(client, b); err != nil {
			t.Fatal(err)
		}
		if b[len(b)-1] != want {
			t.Fatal("query used stale policy/cache", b)
		}
	}
	request(11)
	m.current.Store(snapshot(22))
	request(22)
	client.Close()
	<-done
}

func TestRelayProcessHelper(t *testing.T) {
	if os.Getenv("FASTACL_RELAY_CHILD") != "1" {
		return
	}
	flag.CommandLine = flag.NewFlagSet("relay", flag.ExitOnError)
	os.Args = []string{os.Args[0], "-config", os.Getenv("FASTACL_RELAY_CONFIG")}
	main()
	os.Exit(0)
}

func TestReloadPreservesDaemonPIDAndTCPListener(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("root-only Unix control socket is exercised on the Linux CI runner")
	}
	// Keep the Unix socket path below the Linux sockaddr_un size limit.
	dir, err := os.MkdirTemp("", "fa-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	file := filepath.Join(dir, "dns.json")
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.Addr().String()
	listener.Close()
	cfg := reloadConfig()
	cfg.Listen = addr
	writeConfig(t, file, cfg)
	cmd := exec.Command(os.Args[0], "-test.run=^TestRelayProcessHelper$")
	cmd.Env = append(os.Environ(), "FASTACL_RELAY_CHILD=1", "FASTACL_RELAY_CONFIG="+file)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid := cmd.Process.Pid
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if err = requestReload(file); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("relay did not become ready", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	client, err := net.DialTimeout("tcp4", addr, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	for i := 0; i < 4; i++ {
		cfg.DirectIP = []string{"223.5.5.5", "1.12.12.12"}[i%2]
		writeConfig(t, file, cfg)
		if err := requestReload(file); err != nil {
			t.Fatal(err)
		}
	}
	if cmd.Process.Pid != pid {
		t.Fatal("relay PID changed")
	}
	client.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	_, err = client.Read(make([]byte, 1))
	if timeout, ok := err.(net.Error); !ok || !timeout.Timeout() {
		t.Fatal("existing TCP listener/session was closed", err)
	}
	if err := os.WriteFile(file, []byte("invalid json"), 0600); err != nil {
		t.Fatal(err)
	}
	if requestReload(file) == nil {
		t.Fatal("invalid policy was acknowledged")
	}
	writeConfig(t, file, cfg)
	if err := requestReload(file); err != nil {
		t.Fatal("valid policy could not reload after rejection", err)
	}
}

func TestAllAdvertisedProtocolImplementationsRegistered(t *testing.T) {
	links := []string{
		"socks5://user:pass@192.0.2.1:1080",
		"http://user:pass@192.0.2.1:8080",
		"https://user:pass@example.com:443",
		"trojan://password@example.com:443?sni=example.com",
		"ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@example.com:443",
		"tuic://11111111-1111-4111-8111-111111111111:password@example.com:443?congestion_control=cubic",
		"hysteria2://password@example.com:443?sni=example.com",
		"vless://11111111-1111-4111-8111-111111111111@example.com:443?security=tls&type=tcp&sni=example.com",
	}
	for _, link := range links {
		scheme := link[:bytes.IndexByte([]byte(link), ':')]
		t.Run(scheme, func(t *testing.T) {
			if _, err := makeExits(Config{Exits: map[string]string{"12600": link}}); err != nil {
				t.Fatal(err)
			}
		})
	}
}
