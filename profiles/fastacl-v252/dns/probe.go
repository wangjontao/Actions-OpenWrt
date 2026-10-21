package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"github.com/daeuniverse/outbound/dialer"
	"github.com/daeuniverse/outbound/netproxy"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

type probeSpec struct {
	Link string `json:"link"`
}
type probeSource struct{ name, url, format string }
type probeAnswer struct{ ip, country, location, source, failure string }

var probeSources = []probeSource{
	{"IPIP 国内检测源", "https://myip.ipip.net", "ipip"},
	{"Cloudflare", "https://1.1.1.1/cdn-cgi/trace", "trace"},
	{"ipify", "https://api.ipify.org?format=json", "json"},
}

func publicIP(s string) string {
	ip := net.ParseIP(strings.TrimSpace(s))
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return ""
	}
	// CGNAT addresses are not public egress addresses.
	if v := ip.To4(); v != nil && v[0] == 100 && v[1]&192 == 64 {
		return ""
	}
	return ip.String()
}
func parseProbe(format string, b []byte) probeAnswer {
	var a probeAnswer
	s := strings.TrimSpace(string(b))
	switch format {
	case "trace":
		for _, line := range strings.Split(s, "\n") {
			k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
			if !ok {
				continue
			}
			if k == "ip" {
				a.ip = publicIP(v)
			}
			if k == "loc" && len(v) == 2 && v[0] >= 'A' && v[0] <= 'Z' && v[1] >= 'A' && v[1] <= 'Z' {
				a.country = v
			}
		}
	case "json":
		var v struct {
			IP string `json:"ip"`
		}
		if json.Unmarshal(b, &v) == nil {
			a.ip = publicIP(v.IP)
		}
	case "ipip":
		if !strings.HasPrefix(s, "当前 IP：") {
			break
		}
		fields := strings.Fields(strings.TrimPrefix(s, "当前 IP："))
		if len(fields) == 0 {
			break
		}
		a.ip = publicIP(fields[0])
		if _, loc, ok := strings.Cut(s, "来自于："); ok {
			loc = strings.Join(strings.Fields(loc), " ")
			if len(loc) <= 256 && !strings.ContainsAny(loc, "<>") {
				a.location = loc
			}
			if len(strings.Fields(loc)) > 0 && strings.Fields(loc)[0] == "中国" {
				a.country = "CN"
			}
		}
	}
	return a
}

func probeTransport(d netproxy.Dialer) *http.Transport {
	t := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, Proxy: nil, DisableKeepAlives: true}
	t.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		// Every detection source uses the SAME selected node/chain. No direct retry.
		c, e := d.DialContext(ctx, "tcp", address)
		if e != nil {
			return nil, e
		}
		return &netproxy.FakeNetConn{Conn: c, LAddr: &net.TCPAddr{}, RAddr: &net.TCPAddr{}}, nil
	}
	return t
}
func fetchProbe(ctx context.Context, client *http.Client, s probeSource) probeAnswer {
	a := probeAnswer{source: s.name}
	req, e := http.NewRequestWithContext(ctx, "GET", s.url, nil)
	if e != nil {
		a.failure = "请求配置错误"
		return a
	}
	req.Header.Set("User-Agent", "FastACL/2.5.5 ExitProbe")
	r, e := client.Do(req)
	if e != nil {
		a.failure = "连接失败或超时"
		return a
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		a.failure = fmt.Sprintf("HTTP %d", r.StatusCode)
		return a
	}
	b, e := io.ReadAll(io.LimitReader(r.Body, 16385))
	if e != nil || len(b) > 16384 {
		a.failure = "响应读取失败"
		return a
	}
	parsed := parseProbe(s.format, b)
	parsed.source = s.name
	if parsed.ip == "" {
		parsed.failure = "未返回有效公网 IP"
	}
	return parsed
}
func detectProbe(ctx context.Context, d netproxy.Dialer, sources []probeSource) probeAnswer {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	t := probeTransport(d)
	defer t.CloseIdleConnections()
	client := &http.Client{Transport: t, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return fmt.Errorf("redirect refused") }}
	results := make(chan probeAnswer, len(sources))
	for _, s := range sources {
		go func(s probeSource) { results <- fetchProbe(ctx, client, s) }(s)
	}
	failures := []string{}
	for range sources {
		a := <-results
		if a.ip != "" {
			return a
		}
		failures = append(failures, a.source+"："+a.failure)
	}
	return probeAnswer{failure: "所有检测源均失败，未回退直连（" + strings.Join(failures, "；") + "）"}
}
func runProbe(path string) {
	start := time.Now()
	result := map[string]any{"ok": false}
	defer func() { json.NewEncoder(os.Stdout).Encode(result) }()
	b, e := os.ReadFile(path)
	if e != nil {
		result["error"] = "无法读取检测配置"
		return
	}
	var spec probeSpec
	if json.Unmarshal(b, &spec) != nil {
		result["error"] = "检测配置无效"
		return
	}
	var d netproxy.Dialer = encryptedBase{}
	if spec.Link != "" {
		d, _, e = dialer.NewNetproxyDialerFromLink(d, &dialer.ExtraOption{AllowInsecure: false}, spec.Link)
		if e != nil {
			result["error"] = "节点协议无法检测"
			return
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 11*time.Second)
	defer cancel()
	a := detectProbe(ctx, d, probeSources)
	if a.ip == "" {
		result["error"] = a.failure
		return
	}
	result["ok"] = true
	result["proxy"] = spec.Link != ""
	result["ip"] = a.ip
	result["country"] = a.country
	result["location"] = a.location
	result["source"] = a.source
	result["elapsed_ms"] = time.Since(start).Milliseconds()
}
