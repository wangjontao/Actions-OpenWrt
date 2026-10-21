//go:build linux

package main

import (
	"context"
	"github.com/daeuniverse/outbound/netproxy"
	"net"
	"syscall"
)

type priorityBase struct{}

func (priorityBase) DialContext(ctx context.Context, network, address string) (netproxy.Conn, error) {
	return dialBase(ctx, network, address, true)
}
func priorityControl(network, address string, c syscall.RawConn) error {
	var err error
	e := c.Control(func(fd uintptr) {
		if network == "tcp6" || network == "udp6" {
			err = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_TCLASS, 34<<2)
		} else {
			err = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_TOS, 34<<2)
		}
	})
	if e != nil {
		return e
	}
	return err
}

var _ = net.IPv4len
