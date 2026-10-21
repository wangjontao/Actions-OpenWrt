package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/net/dns/dnsmessage"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

type platformRule struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
}
type platformMapping struct {
	Slot     string `json:"slot"`
	Real     string `json:"real"`
	Platform string `json:"platform"`
 Domain string `json:"domain"`
}
type platformDisk struct {
	Next uint32                     `json:"next"`
	Rows map[string]platformMapping `json:"rows"`
}
type platformStore struct {
	sync.Mutex
	file string
	platformDisk
}

var stores sync.Map

func loadPlatforms(c Config) (map[string][]platformRule, *platformStore, error) {
	needed := false
	check := func(p PolicyConfig) error {
		if len(p.Platforms) > 5 {
			return errors.New("too many platforms")
		}
		if len(p.Platforms) > 0 {
			needed = true
			if p.Exit == 0 || !strings.HasPrefix(p.PlatformSlot, "platform_") || c.DataSlots[p.PlatformSlot] != p.Exit {
				return errors.New("platform slot must match proxy exit")
			}
		}
		return nil
	}
	for _, p := range c.DevicePolicies {
		if e := check(p); e != nil {
			return nil, nil, e
		}
	}
	for _, p := range c.NetworkPolicies {
		if e := check(p); e != nil {
			return nil, nil, e
		}
	}
	if e := check(c.DefaultPolicy); e != nil {
		return nil, nil, e
	}
	if !needed {
		return nil, nil, nil
	}
	b, e := os.ReadFile(c.PlatformRulesFile)
	if e != nil {
		return nil, nil, e
	}
	var doc struct {
		Platforms map[string][]platformRule `json:"platforms"`
	}
	if e = json.Unmarshal(b, &doc); e != nil {
		return nil, nil, e
	}
	allowed := map[string]bool{"tiktok": true, "facebook": true, "instagram": true, "youtube": true, "shopee": true}
	for k, rules := range doc.Platforms {
		if !allowed[k] || len(rules) > 2000 {
			return nil, nil, errors.New("invalid platform catalog")
		}
		for _, r := range rules {
			if (r.Kind != "domain" && r.Kind != "full") || !validDomain(r.Value) {
				return nil, nil, errors.New("invalid platform rule")
			}
		}
	}
	verify := func(p PolicyConfig) error {
		for _, k := range p.Platforms {
			if !allowed[k] || len(doc.Platforms[k]) == 0 {
				return errors.New("unknown platform")
			}
		}
		return nil
	}
	for _, p := range c.DevicePolicies {
		if e = verify(p); e != nil {
			return nil, nil, e
		}
	}
	for _, p := range c.NetworkPolicies {
		if e = verify(p); e != nil {
			return nil, nil, e
		}
	}
	if e = verify(c.DefaultPolicy); e != nil {
		return nil, nil, e
	}
	if !filepath.IsAbs(c.PlatformStateFile) || !strings.HasPrefix(filepath.Clean(c.PlatformStateFile), "/tmp/") {
		return nil, nil, errors.New("platform state must be under /tmp")
	}
	if v, ok := stores.Load(c.PlatformStateFile); ok {
		return doc.Platforms, v.(*platformStore), nil
	}
	s := &platformStore{file: c.PlatformStateFile, platformDisk: platformDisk{Next: 1, Rows: map[string]platformMapping{}}}
	if b, e = os.ReadFile(s.file); e == nil {
		if e = json.Unmarshal(b, &s.platformDisk); e != nil {
			return nil, nil, e
		}
		if s.Next < 1 || s.Next > 60001 || s.Rows == nil || len(s.Rows) > 60000 {
			return nil, nil, errors.New("invalid platform map")
		}
		for ip, m := range s.Rows {
			if !isPlatformIP(ip) || net.ParseIP(m.Real).To4() == nil || !strings.HasPrefix(m.Slot, "platform_") {
				return nil, nil, errors.New("invalid platform mapping")
			}
		}
	} else if !os.IsNotExist(e) {
		return nil, nil, e
	}
	actual, _ := stores.LoadOrStore(s.file, s)
	return doc.Platforms, actual.(*platformStore), nil
}
func isPlatformIP(ip string) bool {
	a := net.ParseIP(ip).To4()
	return a != nil && a[0] == 198 && a[1] == 19
}
func (r *relay) platformName(p PolicyConfig, name string) string {
	for _, tag := range p.Platforms {
		for _, rule := range r.platforms[tag] {
			if name == rule.Value || (rule.Kind == "domain" && domainMatch(name, rule.Value)) {
				return tag
			}
		}
	}
	return ""
}
func (s *platformStore) address(slot, real, tag, domain string) (string, error) {
	s.Lock()
	defer s.Unlock()
	for ip, v := range s.Rows {
		if v.Slot == slot && v.Real == real && v.Platform == tag && v.Domain == domain {
			return ip, nil
		}
	}
	if s.Next > 60000 {
		return "", errors.New("platform address map full")
	}
	n := s.Next
	ip := fmt.Sprintf("198.19.%d.%d", n>>8, n&255)
	s.Rows[ip] = platformMapping{Slot:slot,Real:real,Platform:tag,Domain:domain}
	s.Next++
	b, e := json.Marshal(s.platformDisk)
	if e == nil {
		e = os.WriteFile(s.file+".new", b, 0600)
	}
	if e == nil {
		e = os.Rename(s.file+".new", s.file)
	}
	if e != nil {
		delete(s.Rows, ip)
		s.Next--
		return "", e
	}
	return ip, nil
}
func (r *relay) platformAddress(slot, address string) (string, error) {
	host, port, e := net.SplitHostPort(address)
	if e != nil {
		return "", e
	}
	if !isPlatformIP(host) {
		return "", errors.New("platform-only entry rejects unclassified traffic")
	}
	if r.platformMap == nil {
		return "", errors.New("platform mapping unavailable")
	}
	r.platformMap.Lock()
	row, ok := r.platformMap.Rows[host]
	r.platformMap.Unlock()
	if !ok || row.Slot != slot {
		return "", errors.New("platform address not owned by slot")
	}
 p,found:=r.platformPolicy(slot)
 if !found||row.Domain==""||r.platformName(p,row.Domain)!=row.Platform{return "",errors.New("platform selection changed")}
 for _,blocked:=range p.BlockDomains{if domainMatch(row.Domain,blocked){return "",errors.New("platform domain blocked")}}
 return net.JoinHostPort(row.Real, port), nil
}
func (r *relay) platformRewrite(q, b []byte, ip string) []byte {
	p := r.scopedPolicy(ip)
	tag := r.platformName(p, questionName(q))
	if tag == "" || len(b) < 12 || b[3]&15 != 0 {
		return b
	}
	var query, reply dnsmessage.Message
	if query.Unpack(q) != nil || reply.Unpack(b) != nil || len(query.Questions) != 1 {
		return nil
	}
	kind := query.Questions[0].Type
	if kind != dnsmessage.TypeA && kind != dnsmessage.TypeAAAA && kind != dnsmessage.Type(65) {
		return b
	}
	result := dnsmessage.Message{Header: dnsmessage.Header{ID: query.ID, Response: true, RecursionDesired: query.RecursionDesired, RecursionAvailable: reply.RecursionAvailable}, Questions: query.Questions}
	if kind == dnsmessage.TypeA {
		if r.platformMap == nil {
			return nil
		}
		seen := map[string]bool{}
		for _, ans := range reply.Answers {
			if body, ok := ans.Body.(*dnsmessage.AResource); ok {
				real := net.IP(body.A[:]).String()
				fake, e := r.platformMap.address(p.PlatformSlot, real, tag, questionName(q))
				if e != nil {
					return nil
				}
				if seen[fake] {
					continue
				}
				seen[fake] = true
				parsed := net.ParseIP(fake).To4()
				var a [4]byte
				copy(a[:], parsed)
				result.Answers = append(result.Answers, dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: query.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: a}})
			}
		}
	}
	out, e := result.Pack()
	if e != nil {
		return nil
	}
	return out
}

var _ = strconv.Itoa

func(r *relay)platformPolicy(slot string)(PolicyConfig,bool){
 for _,p:=range r.config.DevicePolicies{if p.PlatformSlot==slot{return p,true}}
 for _,p:=range r.config.NetworkPolicies{if p.PlatformSlot==slot{return p,true}}
 if r.config.DefaultPolicy.PlatformSlot==slot{return r.config.DefaultPolicy,true}
 return PolicyConfig{},false
}
