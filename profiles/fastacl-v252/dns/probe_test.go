package main

import (
	"context"
	"errors"
	"github.com/daeuniverse/outbound/netproxy"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestProbeParsers(t *testing.T) {
	for _, x := range []struct{ format, body, ip, country string }{
		{"ipip", "当前 IP：42.237.26.134  来自于：中国 河南 安阳 联通\n", "42.237.26.134", "CN"},
		{"trace", "ip=160.248.81.31\nloc=JP\n", "160.248.81.31", "JP"},
		{"json", `{"ip":"8.8.8.8"}`, "8.8.8.8", ""},
		{"ipip", "<html>42.237.26.134</html>", "", ""},
		{"json", `{"ip":"192.168.1.1"}`, "", ""},
		{"json", `{"ip":"100.64.0.1"}`, "", ""},
	} {
		a := parseProbe(x.format, []byte(x.body))
		if a.ip != x.ip || a.country != x.country {
			t.Fatalf("%+v => %+v", x, a)
		}
	}
}

type deniedDialer struct {
	mu        sync.Mutex
	addresses []string
}

func (d *deniedDialer) DialContext(_ context.Context, _, address string) (netproxy.Conn, error) {
	d.mu.Lock()
	d.addresses = append(d.addresses, address)
	d.mu.Unlock()
	return nil, errors.New("test proxy unavailable")
}
func TestEverySourceStaysOnSelectedDialer(t *testing.T) {
	d := &deniedDialer{}
	a := detectProbe(context.Background(), d, probeSources)
	if a.ip != "" || !strings.Contains(a.failure, "未回退直连") {
		t.Fatal(a)
	}
	if len(d.addresses) != len(probeSources) {
		t.Fatal(d.addresses)
	}
	for _, host := range []string{"myip.ipip.net:443", "1.1.1.1:443", "api.ipify.org:443"} {
		found := false
		for _, got := range d.addresses {
			found = found || got == host
		}
		if !found {
			t.Fatal(host, d.addresses)
		}
	}
}
func TestDomesticResponseAndRedirect(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "/", 302)
			return
		}
		w.Write([]byte("当前 IP：42.237.26.134 来自于：中国 河南 安阳 联通"))
	}))
	defer s.Close()
	c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("refused") }}
	a := fetchProbe(context.Background(), c, probeSource{"test", s.URL, "ipip"})
	if a.ip != "42.237.26.134" || a.country != "CN" {
		t.Fatal(a)
	}
	a = fetchProbe(context.Background(), c, probeSource{"test", s.URL + "/redirect", "ipip"})
	if a.ip != "" || a.failure == "" {
		t.Fatal(a)
	}
}
