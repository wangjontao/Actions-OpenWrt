package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

type dnsCounters struct{ Queries, Direct, Proxy, Blocked, Errors atomic.Uint64 }

func (s *dnsCounters) snapshot() map[string]uint64 {
	return map[string]uint64{"queries": s.Queries.Load(), "direct": s.Direct.Load(), "proxy": s.Proxy.Load(), "blocked": s.Blocked.Load(), "errors": s.Errors.Load()}
}
func validDomain(s string) bool {
	if s == "" || len(s) > 253 || s != strings.ToLower(s) || net.ParseIP(s) != nil {
		return false
	}
	for _, part := range strings.Split(s, ".") {
		if len(part) == 0 || len(part) > 63 || part[0] == '-' || part[len(part)-1] == '-' {
			return false
		}
		for _, c := range part {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return true
}
func domainMatch(domain, suffix string) bool {
	return domain == suffix || strings.HasSuffix(domain, "."+suffix)
}
func (r *relay) networkPolicy(ip string) (PolicyConfig, bool) {
	addr := net.ParseIP(ip)
	best := -1
	var out PolicyConfig
	for cidr, p := range r.config.NetworkPolicies {
		_, n, e := net.ParseCIDR(cidr)
		if e == nil && n.Contains(addr) {
			bits, _ := n.Mask.Size()
			if bits > best {
				best = bits
				out = p
			}
		}
	}
	return out, best >= 0
}
func (r *relay) scopedPolicy(ip string) PolicyConfig {
	if p, ok := r.config.DevicePolicies[ip]; ok {
		return p
	}
	if p, ok := r.networkPolicy(ip); ok {
		return p
	}
	return r.config.DefaultPolicy
}
func questionName(q []byte) string {
	if len(q) < 12 {
		return ""
	}
	at := 12
	labels := []string{}
	seen := map[int]bool{}
	length := 0
	for steps := 0; steps < 128; steps++ {
		if at >= len(q) || seen[at] {
			return ""
		}
		seen[at] = true
		n := int(q[at])
		at++
		if n == 0 {
			return strings.ToLower(strings.Join(labels, "."))
		}
		if n&192 == 192 {
			if at >= len(q) {
				return ""
			}
			at = (n&63)*256 + int(q[at])
			continue
		}
		if n > 63 || at+n > len(q) {
			return ""
		}
		length += n + 1
		if length > 254 {
			return ""
		}
		labels = append(labels, string(q[at:at+n]))
		at += n
	}
	return ""
}
func (r *relay) domainPolicy(ip string, q []byte) (string, int, bool) {
	id, exit := r.policyFor(ip)
	p := r.scopedPolicy(ip)
	name := questionName(q)
	for _, d := range p.BlockDomains {
		if domainMatch(name, d) {
			return id, exit, true
		}
	}
	if r.platformName(p,name)!="" {return id,exit,false}
	if p.DomesticResolver != "" {
		for d := name; d != ""; {
			if _, ok := r.domestic[d]; ok {
				return p.DomesticResolver, 0, false
			}
			i := strings.IndexByte(d, '.')
			if i < 0 {
				break
			}
			d = d[i+1:]
		}
	}
	return id, exit, false
}
func loadDomainConfig(c Config) (map[string]struct{}, error) {
	needed := false
	check := func(p PolicyConfig) error {
		if len(p.BlockDomains) > 64 {
			return errors.New("too many blocked domains")
		}
		for _, d := range p.BlockDomains {
			if !validDomain(d) {
				return errors.New("invalid blocked domain")
			}
		}
		if p.DomesticResolver != "" {
			needed = true
			if p.Exit == 0 {
				return errors.New("DNS split requires proxy policy")
			}
			v, ok := c.Resolvers[p.DomesticResolver]
			if !ok || v.IP == "" {
				return errors.New("missing domestic resolver")
			}
		}
		return nil
	}
	for _, p := range c.DevicePolicies {
		if e := check(p); e != nil {
			return nil, e
		}
	}
	for _, p := range c.NetworkPolicies {
		if e := check(p); e != nil {
			return nil, e
		}
	}
	if e := check(c.DefaultPolicy); e != nil {
		return nil, e
	}
	if !needed {
		return nil, nil
	}
	if c.DomesticDomainsFile != "/usr/share/fastacl252/cn-domains.txt" {
		return nil, errors.New("invalid domestic domain data path")
	}
	f, e := os.Open(c.DomesticDomainsFile)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	out := map[string]struct{}{"cn": {}}
	scanner := bufio.NewScanner(io.LimitReader(f, 8*1024*1024))
	count := 0
	for scanner.Scan() {
		s := strings.TrimSpace(scanner.Text())
		if !validDomain(s) {
			return nil, errors.New("invalid domestic domain data")
		}
		out[s] = struct{}{}
		count++
	}
	if e = scanner.Err(); e != nil {
		return nil, e
	}
	if count < 10000 {
		return nil, errors.New("incomplete domestic domain data")
	}
	return out, nil
}
func (r *relay) explain(ip, name string) {
	name = strings.TrimSuffix(strings.ToLower(name), ".")
	if !validDomain(name) {
		fmt.Println(`{"error":"invalid domain"}`)
		return
	}
	q := make([]byte, 12)
	q[5] = 1
	for _, s := range strings.Split(name, ".") {
		q = append(q, byte(len(s)))
		q = append(q, s...)
	}
	q = append(q, 0, 0, 1, 0, 1)
	id, exit, block := r.domainPolicy(ip, q)
	path := "direct"
	if exit != 0 {
		path = "proxy"
	}
	if block {
		path = "blocked"
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{"resolver": id, "path": path, "exit": exit})
}
func requestStats(file string) error {
	c, e := net.DialTimeout("unix", file+".sock", time.Second)
	if e != nil {
		return e
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	if _, e = io.WriteString(c, "stats\n"); e != nil {
		return e
	}
	var result map[string]uint64
	if e = json.NewDecoder(io.LimitReader(c, 8192)).Decode(&result); e != nil {
		return e
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}
