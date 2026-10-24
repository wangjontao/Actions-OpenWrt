package main

// A stable authenticated SOCKS endpoint decouples the immutable dae datapath
// from per-device/WiFi exit selection. Only this manager's snapshot changes.
import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"github.com/daeuniverse/outbound/netproxy"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

type slotSession struct {
	key    string
	conn   net.Conn
	cancel context.CancelFunc
}
type slotTracker struct {
	mu       sync.Mutex
	sessions map[*slotSession]struct{}
	limit    chan struct{}
	udpLimit chan struct{}
}

// A nil limiter accepts connections without an application-level cap.
func newSlotLimit(n int) chan struct{} {
	if n <= 0 {
		return nil
	}
	return make(chan struct{}, n)
}
func acquireSlot(limit chan struct{}) bool {
	if limit == nil {
		return true
	}
	select {
	case limit <- struct{}{}:
		return true
	default:
		return false
	}
}
func releaseSlot(limit chan struct{}) {
	if limit != nil {
		<-limit
	}
}

func (m *relayManager) publish(next *relay) {
	m.data.mu.Lock()
	defer m.data.mu.Unlock()
	old := m.current.Load()
	m.current.Store(next)
	if old == nil {
		return
	}
	for s := range m.data.sessions {
		if slotIdentity(old, s.key) != slotIdentity(next, s.key) {
			s.cancel()
			s.conn.Close()
		}
	}
}
func slotIdentity(r *relay, key string) string {
	id, ok := r.config.DataSlots[key]
	if !ok {
		return "missing"
	}
	if id == 0 {
		return "direct"
	}
	p, _ := r.platformPolicy(key)
	b, _ := json.Marshal(p)
	return r.config.Exits[strconv.Itoa(id)] + string(b)
}
func (m *relayManager) serveSlots() (net.Listener, error) {
	r := m.current.Load()
	if r.config.DataListen == "" {
		return nil, nil
	}
	l, e := net.Listen("tcp4", r.config.DataListen)
	if e != nil {
		return nil, e
	}
	m.data.sessions = map[*slotSession]struct{}{}
	m.data.limit = newSlotLimit(r.config.DataMaxConnections)
	m.data.udpLimit = newSlotLimit(r.config.DataMaxUDPFlows)
	go func() {
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			if acquireSlot(m.data.limit) {
				go func() { defer releaseSlot(m.data.limit); m.slot(c) }()
			} else {
				c.Close()
			}
		}
	}()
	return l, nil
}
func readByte(r io.Reader) (byte, error) { var b [1]byte; _, e := io.ReadFull(r, b[:]); return b[0], e }
func readSocksAddress(r io.Reader) (string, []byte, error) {
	t, e := readByte(r)
	if e != nil {
		return "", nil, e
	}
	raw := []byte{t}
	var host string
	switch t {
	case 1, 4:
		n := 4
		if t == 4 {
			n = 16
		}
		b := make([]byte, n)
		if _, e = io.ReadFull(r, b); e != nil {
			return "", nil, e
		}
		host = net.IP(b).String()
		raw = append(raw, b...)
	case 3:
		n, e := readByte(r)
		if e != nil || n == 0 {
			return "", nil, errors.New("invalid SOCKS domain")
		}
		b := make([]byte, int(n))
		if _, e = io.ReadFull(r, b); e != nil {
			return "", nil, e
		}
		host = string(b)
		raw = append(append(raw, n), b...)
		if strings.ContainsAny(host, "\x00\r\n") {
			return "", nil, errors.New("invalid domain")
		}
	default:
		return "", nil, errors.New("invalid SOCKS address")
	}
	var port [2]byte
	if _, e = io.ReadFull(r, port[:]); e != nil {
		return "", nil, e
	}
	raw = append(raw, port[:]...)
	return net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(port[:])))), raw, nil
}
func socksReply(c net.Conn, status byte, a *net.UDPAddr) error {
	b := []byte{5, status, 0, 1, 0, 0, 0, 0, 0, 0}
	if a != nil {
		copy(b[4:8], a.IP.To4())
		binary.BigEndian.PutUint16(b[8:], uint16(a.Port))
	}
	_, e := c.Write(b)
	return e
}
func (m *relayManager) slot(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	v, e := readByte(c)
	if e != nil || v != 5 {
		return
	}
	count, e := readByte(c)
	if e != nil || count == 0 {
		return
	}
	methods := make([]byte, int(count))
	if _, e = io.ReadFull(c, methods); e != nil {
		return
	}
	auth := false
	for _, b := range methods {
		if b == 2 {
			auth = true
		}
	}
	if !auth {
		c.Write([]byte{5, 255})
		return
	}
	if _, e = c.Write([]byte{5, 2}); e != nil {
		return
	}
	v, e = readByte(c)
	if e != nil || v != 1 {
		return
	}
	n, e := readByte(c)
	if e != nil || n == 0 {
		return
	}
	user := make([]byte, int(n))
	if _, e = io.ReadFull(c, user); e != nil {
		return
	}
	n, e = readByte(c)
	if e != nil {
		return
	}
	password := make([]byte, int(n))
	if _, e = io.ReadFull(c, password); e != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	key := string(user)
	s := &slotSession{key: key, conn: c, cancel: cancel}
	m.data.mu.Lock()
	r := m.current.Load()
	id, exists := r.config.DataSlots[key]
	valid := exists && subtle.ConstantTimeCompare(password, []byte(r.config.DataSecret)) == 1
	var d netproxy.Dialer
	if valid {
		if id == 0 {
			d = encryptedBase{}
		} else {
			d = r.exits[id]
			if strings.HasPrefix(key, "platform_") {
				d = r.priorityExits[id]
			}
		}
		valid = d != nil
	}
	if valid {
		m.data.sessions[s] = struct{}{}
	}
	m.data.mu.Unlock()
	if !valid {
		c.Write([]byte{1, 1})
		return
	}
	defer func() { m.data.mu.Lock(); delete(m.data.sessions, s); m.data.mu.Unlock() }()
	if _, e = c.Write([]byte{1, 0}); e != nil {
		return
	}
	var request [3]byte
	if _, e = io.ReadFull(c, request[:]); e != nil || request[0] != 5 || request[2] != 0 {
		return
	}
	address, _, e := readSocksAddress(c)
	if e != nil {
		return
	}
	if strings.HasPrefix(key, "platform_") && request[1] == 1 {
		address, e = r.platformAddress(key, address)
		if e != nil {
			socksReply(c, 2, nil)
			return
		}
	}
	c.SetDeadline(time.Time{})
	switch request[1] {
	case 1:
		dialCtx, stop := context.WithTimeout(ctx, 8*time.Second)
		remote, e := d.DialContext(dialCtx, "tcp", address)
		stop()
		if e != nil {
			socksReply(c, 5, nil)
			return
		}
		defer remote.Close()
		bridgeDone := make(chan struct{})
		defer close(bridgeDone)
		go func() {
			select {
			case <-ctx.Done():
				remote.Close()
				c.Close()
			case <-bridgeDone:
			}
		}()
		if socksReply(c, 0, nil) != nil {
			return
		}
		done := make(chan struct{})
		go func() { io.Copy(remote, c); netproxy.ForwardCloseWrite(remote); close(done) }()
		io.Copy(c, remote)
		c.Close()
		remote.Close()
		<-done
	case 3:
		m.slotUDP(c, d, r, key)
	default:
		socksReply(c, 7, nil)
	}
}
func (m *relayManager) slotUDP(c net.Conn, d netproxy.Dialer, r *relay, key string) {
	// One UDP association belongs to its authenticated TCP connection. Pin the
	// first datagram's endpoint and never accept packets from another address.
	peer := c.RemoteAddr().(*net.TCPAddr).IP
	local := c.LocalAddr().(*net.TCPAddr).IP
	u, e := net.ListenUDP("udp4", &net.UDPAddr{IP: local})
	if e != nil {
		socksReply(c, 1, nil)
		return
	}
	defer u.Close()
	if socksReply(c, 0, u.LocalAddr().(*net.UDPAddr)) != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { var b [1]byte; c.Read(b[:]); cancel(); u.Close() }()
	type flow struct {
		conn   netproxy.Conn
		header []byte
	}
	var mu sync.Mutex
	flows := map[string]*flow{}
	var endpoint *net.UDPAddr
	defer func() {
		mu.Lock()
		defer mu.Unlock()
		for _, f := range flows {
			f.conn.Close()
		}
	}()
	buf := make([]byte, 65535)
	for {
		n, from, e := u.ReadFromUDP(buf)
		if e != nil {
			return
		}
		if !from.IP.Equal(peer) || n < 7 || buf[0] != 0 || buf[1] != 0 || buf[2] != 0 {
			continue
		}
		if endpoint != nil && (endpoint.Port != from.Port || !endpoint.IP.Equal(from.IP)) {
			continue
		}
		address, raw, e := readSocksAddress(bytes.NewReader(buf[3:n]))
		if e != nil {
			continue
		}
		off := 3 + len(raw)
		if off >= n {
			continue
		}
		if endpoint == nil {
			endpoint = from
		}
		mu.Lock()
		f := flows[address]
		size := len(flows)
		mu.Unlock()
		if f == nil {
			if cap := r.config.DataMaxUDPFlowsPerSession; cap > 0 && size >= cap {
				continue
			}
			if !acquireSlot(m.data.udpLimit) {
				continue
			}
			dialCtx, stop := context.WithTimeout(ctx, 5*time.Second)
			target := address
			if strings.HasPrefix(key, "platform_") {
				target, e = r.platformAddress(key, address)
			}
			if e != nil {
				stop()
				releaseSlot(m.data.udpLimit)
				continue
			}
			remote, e := d.DialContext(dialCtx, "udp", target)
			stop()
			if e != nil {
				releaseSlot(m.data.udpLimit)
				continue
			}
			f = &flow{remote, append([]byte{0, 0, 0}, raw...)}
			mu.Lock()
			flows[address] = f
			mu.Unlock()
			dst := endpoint
			go func(address string, f *flow) {
				defer func() { releaseSlot(m.data.udpLimit) }()
				defer func() { f.conn.Close(); mu.Lock(); delete(flows, address); mu.Unlock() }()
				b := make([]byte, 65535)
				for {
					f.conn.SetReadDeadline(time.Now().Add(30 * time.Second))
					n, e := f.conn.Read(b)
					if e != nil {
						return
					}
					if len(f.header)+n <= 65507 {
						u.WriteToUDP(append(append([]byte(nil), f.header...), b[:n]...), dst)
					}
				}
			}(address, f)
		}
		f.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if _, e = f.conn.Write(buf[off:n]); e != nil {
			f.conn.Close()
		}
	}
}
