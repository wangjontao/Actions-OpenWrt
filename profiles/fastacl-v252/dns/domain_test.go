package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

func domainQuery(s string) []byte {
	q := make([]byte, 12)
	q[2] = 1
	q[5] = 1
	for _, part := range strings.Split(s, ".") {
		q = append(q, byte(len(part)))
		q = append(q, part...)
	}
	return append(q, 0, 0, 1, 0, 1)
}
func domainRelay() *relay {
	return &relay{config: Config{Resolvers: map[string]ResolverConfig{"cn": {Type: "doh", IP: "223.5.5.5", Name: "dns.alidns.com"}, "foreign": {Type: "doh", IP: "1.1.1.1", Name: "cloudflare-dns.com"}}, DevicePolicies: map[string]PolicyConfig{"192.168.7.100": {Resolver: "foreign", Exit: 12600, DomesticResolver: "cn", BlockDomains: []string{"ads.example.com"}}, "192.168.7.101": {Resolver: "foreign", Exit: 12601}}, DefaultPolicy: PolicyConfig{Resolver: "cn"}}, domestic: map[string]struct{}{"cn": {}, "baidu.com": {}}, namedClients: map[string]*http.Client{}, cache: map[string]entry{}, slots: make(chan struct{}, 64)}
}
func TestDomainDNSIsolation(t *testing.T) {
	r := domainRelay()
	cases := []struct {
		ip, name, id string
		exit         int
		block        bool
	}{{"192.168.7.100", "WWW.BAIDU.COM", "cn", 0, false}, {"192.168.7.100", "a.example.cn", "cn", 0, false}, {"192.168.7.100", "baidu.com.evil.test", "foreign", 12600, false}, {"192.168.7.100", "www.google.com", "foreign", 12600, false}, {"192.168.7.100", "a.ads.example.com", "foreign", 12600, true}, {"192.168.7.100", "notads.example.com", "foreign", 12600, false}, {"192.168.7.101", "baidu.com", "foreign", 12601, false}}
	for _, x := range cases {
		id, exit, b := r.domainPolicy(x.ip, domainQuery(x.name))
		if id != x.id || exit != x.exit || b != x.block {
			t.Fatal(x, id, exit, b)
		}
	}
}
func TestDomainBlockedBeforeAnyDial(t *testing.T) {
	r := domainRelay()
	b := r.resolve(domainQuery("sub.ads.example.com"), "192.168.7.100")
	if b[3]&15 != 5 || binary.BigEndian.Uint16(b[6:8]) != 0 || r.stats.Blocked.Load() != 1 {
		t.Fatal("domain not refused")
	}
}
func TestForeignDNSFailureNeverUsesDomestic(t *testing.T) {
	r := domainRelay()
	r.namedClients["foreign@12600"] = &http.Client{Transport: roundFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("proxy down") })}
	r.namedClients["cn@0"] = &http.Client{Transport: roundFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("foreign query leaked to direct DNS")
		return nil, nil
	})}
	b := r.resolve(domainQuery("www.google.com"), "192.168.7.100")
	if b[3]&15 != 2 || r.stats.Errors.Load() != 1 {
		t.Fatal("expected fail closed")
	}
}
func TestDomesticAndProxyCachePaths(t *testing.T) {
	r := domainRelay()
	calls := map[string]int{}
	for _, key := range []string{"cn@0", "foreign@12600", "foreign@12601"} {
		key := key
		r.namedClients[key] = &http.Client{Transport: roundFunc(func(req *http.Request) (*http.Response, error) {
			calls[key]++
			q, _ := io.ReadAll(req.Body)
			return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(answer(q)))}, nil
		})}
	}
	for i := 0; i < 2; i++ {
		r.resolve(domainQuery("baidu.com"), "192.168.7.100")
		r.resolve(domainQuery("baidu.com"), "192.168.7.101")
		r.resolve(domainQuery("google.com"), "192.168.7.100")
	}
	for k, v := range calls {
		if v != 1 {
			t.Fatal("cache path not isolated", k, v)
		}
	}
	if len(calls) != 3 || r.stats.Direct.Load() != 2 || r.stats.Proxy.Load() != 4 {
		t.Fatal("wrong DNS paths/counters", calls)
	}
}
func TestDNSLongestPrefixWins(t *testing.T) {
	r := domainRelay()
	r.config.NetworkPolicies = map[string]PolicyConfig{"172.16.0.0/16": {Resolver: "foreign", Exit: 12600}, "172.16.1.0/24": {Resolver: "foreign", Exit: 12601}}
	for i := 0; i < 100; i++ {
		_, exit := r.policyFor("172.16.1.5")
		if exit != 12601 {
			t.Fatal("wrong scoped policy")
		}
	}
}
func TestDNSDomainInputValidation(t *testing.T) {
	for _, name := range []string{"", "a..com", "-a.com", "a-.com", "1.2.3.4", "evil.com;reboot", "*.example.com"} {
		if validDomain(name) {
			t.Fatal(name)
		}
	}
	if !validDomain("xn--fiqs8s.com") {
		t.Fatal("punycode rejected")
	}
	if questionName([]byte{0}) != "" {
		t.Fatal("malformed accepted")
	}
	q := domainQuery("a.com")
	q[12] = 192
	q[13] = 12
	if questionName(q) != "" {
		t.Fatal("compression loop accepted")
	}
}
