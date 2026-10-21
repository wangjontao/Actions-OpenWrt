//go:build !linux

package main

import (
	"context"
	"github.com/daeuniverse/outbound/netproxy"
	"syscall"
)

type priorityBase struct{}

func (priorityBase) DialContext(ctx context.Context, network, address string) (netproxy.Conn, error) {
	return dialBase(ctx, network, address, false)
}
func priorityControl(network, address string, c syscall.RawConn) error { return nil }
