package main

import (
	"context"
	"fmt"
	"github.com/daeuniverse/outbound/dialer"
	"github.com/daeuniverse/outbound/netproxy"
	"io"
	"net"
	"testing"
	"time"
)

type slotTestDialer struct{ tcp, udp string }

func (d slotTestDialer) DialContext(ctx context.Context, network, address string) (netproxy.Conn, error) {
	n := &net.Dialer{}
	if network == "udp" {
		return n.DialContext(ctx, "udp", d.udp)
	}
	return n.DialContext(ctx, "tcp", d.tcp)
}
func slotBackend(t *testing.T, label string) slotTestDialer {
	t.Helper()
	tcp, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	udp, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { tcp.Close(); udp.Close() })
	go func() {
		for {
			c, e := tcp.Accept()
			if e != nil {
				return
			}
			go func() {
				defer c.Close()
				b := make([]byte, 1024)
				for {
					n, e := c.Read(b)
					if e != nil {
						return
					}
					if _, e = c.Write(append([]byte(label), b[:n]...)); e != nil {
						return
					}
				}
			}()
		}
	}()
	go func() {
		b := make([]byte, 1024)
		for {
			n, a, e := udp.ReadFrom(b)
			if e != nil {
				return
			}
			udp.WriteTo(append([]byte(label), b[:n]...), a)
		}
	}()
	return slotTestDialer{tcp.Addr().String(), udp.LocalAddr().String()}
}
func slotFixture(t *testing.T) (*relayManager, string, *relay) {
	t.Helper()
	a := slotBackend(t, "A:")
	b := slotBackend(t, "B:")
	r := &relay{config: Config{DataListen: "127.0.0.1:0", DataSecret: "0123456789abcdef0123456789abcdef", DataSlots: map[string]int{"wifi_a1": 12600, "wifi_a2": 12601}, Exits: map[string]string{"12600": "exit-a", "12601": "exit-b"}}, exits: map[int]netproxy.Dialer{12600: a, 12601: b}}
	m := &relayManager{}
	m.publish(r)
	l, e := m.serveSlots()
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { l.Close(); m.publish(&relay{config: Config{}}) })
	return m, l.Addr().String(), r
}
func slotClient(t *testing.T, address, key, secret, network string) (netproxy.Conn, error) {
	t.Helper()
	d, _, e := dialer.NewNetproxyDialerFromLink(encryptedBase{}, &dialer.ExtraOption{}, fmt.Sprintf("socks5://%s:%s@%s", key, secret, address))
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return d.DialContext(ctx, network, "198.18.0.1:1234")
}
func slotExchange(t *testing.T, c netproxy.Conn, want string) {
	t.Helper()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	if _, e := c.Write([]byte("ping")); e != nil {
		t.Fatal(e)
	}
	b := make([]byte, len(want))
	if _, e := io.ReadFull(c, b); e != nil {
		t.Fatal(e)
	}
	if string(b) != want {
		t.Fatalf("got %q want %q", b, want)
	}
}
func TestSlotSwitchOnlyClosesChangedWiFi(t *testing.T) {
	m, address, r := slotFixture(t)
	secret := r.config.DataSecret
	first, e := slotClient(t, address, "wifi_a1", secret, "tcp")
	if e != nil {
		t.Fatal(e)
	}
	defer first.Close()
	other, e := slotClient(t, address, "wifi_a2", secret, "tcp")
	if e != nil {
		t.Fatal(e)
	}
	defer other.Close()
	slotExchange(t, first, "A:ping")
	slotExchange(t, other, "B:ping")
	next := &relay{config: r.config, exits: r.exits}
	next.config.DataSlots = map[string]int{"wifi_a1": 12601, "wifi_a2": 12601}
	m.publish(next)
	first.SetReadDeadline(time.Now().Add(time.Second))
	var b [1]byte
	if _, e = first.Read(b[:]); e == nil {
		t.Fatal("changed WiFi kept old exit connection")
	}
	slotExchange(t, other, "B:ping")
	changed, e := slotClient(t, address, "wifi_a1", secret, "tcp")
	if e != nil {
		t.Fatal(e)
	}
	defer changed.Close()
	slotExchange(t, changed, "B:ping")
}
func TestSlotUDPAndAuthentication(t *testing.T) {
	_, address, r := slotFixture(t)
	if c, e := slotClient(t, address, "wifi_a1", "wrong", "tcp"); e == nil {
		c.Close()
		t.Fatal("invalid password accepted")
	}
	if c, e := slotClient(t, address, "missing", r.config.DataSecret, "tcp"); e == nil {
		c.Close()
		t.Fatal("unknown target fell back to direct")
	}
	c, e := slotClient(t, address, "wifi_a1", r.config.DataSecret, "udp")
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	if _, e = c.Write([]byte("ping")); e != nil {
		t.Fatal(e)
	}
	b := make([]byte, 65535)
	n, e := c.Read(b)
	if e != nil {
		t.Fatal(e)
	}
	if string(b[:n]) != "A:ping" {
		t.Fatalf("unexpected UDP reply %q", b[:n])
	}
}

// Keep all connections open together: the old global 128 cap rejects #129.
func TestSlotsBeyondOldGlobalLimit(t *testing.T) {
	_, address, r := slotFixture(t)
	for i := 0; i < 256; i++ {
		c, err := slotClient(t, address, "wifi_a1", r.config.DataSecret, "tcp")
		if err != nil {
			t.Fatalf("connection %d: %v", i+1, err)
		}
		t.Cleanup(func() { c.Close() })
		c.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err = c.Write([]byte("x")); err != nil {
			t.Fatal(err)
		}
		b := make([]byte, 3)
		if _, err = io.ReadFull(c, b); err != nil || string(b) != "A:x" {
			t.Fatalf("connection %d echo %q: %v", i+1, b, err)
		}
		c.SetDeadline(time.Time{})
	}
}
func TestOptionalSlotLimit(t *testing.T) {
	unlimited := newSlotLimit(0)
	for i := 0; i < 2048; i++ {
		if !acquireSlot(unlimited) {
			t.Fatal("default must be unlimited")
		}
		releaseSlot(unlimited)
	}
	limited := newSlotLimit(2)
	if !acquireSlot(limited) || !acquireSlot(limited) || acquireSlot(limited) {
		t.Fatal("explicit cap not respected")
	}
	releaseSlot(limited)
	if !acquireSlot(limited) {
		t.Fatal("released capacity not reusable")
	}
}

func TestUDPFlowsBeyondOldGlobalLimit(t *testing.T) {
	_, address, r := slotFixture(t)
	for i := 0; i < 80; i++ {
		c, e := slotClient(t, address, "wifi_a1", r.config.DataSecret, "udp")
		if e != nil {
			t.Fatalf("UDP session %d: %v", i+1, e)
		}
		t.Cleanup(func() { c.Close() })
		c.SetDeadline(time.Now().Add(3 * time.Second))
		if _, e = c.Write([]byte("ping")); e != nil {
			t.Fatal(e)
		}
		b := make([]byte, 32)
		n, e := c.Read(b)
		if e != nil || string(b[:n]) != "A:ping" {
			t.Fatalf("UDP flow %d reply %q: %v", i+1, b[:n], e)
		}
	}
}
