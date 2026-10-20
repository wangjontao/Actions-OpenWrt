package main

import (
	"errors"
	"net"
	"net/netip"
)

// Native proxy transports need PacketConn in addition to stream-like UDP.
// Keep the original encrypted resolver's peer pinned; never resolve a new
// address through a process/system resolver in WriteTo.
type pinnedUDPConn struct {
	*net.UDPConn
	target string
}

func (c *pinnedUDPConn) ReadFrom(b []byte) (int, netip.AddrPort, error) {
	n, e := c.Read(b)
	return n, c.RemoteAddr().(*net.UDPAddr).AddrPort(), e
}
func (c *pinnedUDPConn) WriteTo(b []byte, address string) (int, error) {
	if address != c.target && address != c.RemoteAddr().String() {
		return 0, errors.New("UDP peer change refused")
	}
	return c.Write(b)
}
