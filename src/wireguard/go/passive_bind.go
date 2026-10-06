/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */

package main

import (
	"errors"
	"net"
	"net/netip"
	"strconv"
	"sync"

	"golang.zx2c4.com/wireguard/conn"
)

const passiveBatchSize = 16
const passiveMaxDatagram = 65535

var (
	errPassivePacket = errors.New("invalid passive datagram")
	errPassivePort   = errors.New("passive bind requires the host-selected port")
	errPassiveMark   = errors.New("passive bind does not support nonzero marks")
)

// passiveBind never creates or operates a socket. The host owns the transport
// throughout close/reopen and must keep its port fixed for this device lifetime.
type passiveBind struct {
	host    *passiveHost
	read    func([][]byte, []int, []conn.Endpoint, <-chan struct{}) (int, error)
	mu      sync.RWMutex
	port    uint16
	send    func([][]byte, netip.AddrPort) error
	session chan struct{}
}

var _ conn.Bind = (*passiveBind)(nil)

func newPassiveBind(port uint16, read func([][]byte, []int, []conn.Endpoint, <-chan struct{}) (int, error), send func([][]byte, netip.AddrPort) error) *passiveBind {
	return &passiveBind{port: port, read: read, send: send}
}

func (b *passiveBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.session != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	if b.port == 0 || (port != 0 && port != b.port) {
		return nil, 0, errPassivePort
	}
	done := make(chan struct{})
	b.session = done
	receive := func(packets [][]byte, sizes []int, endpoints []conn.Endpoint) (int, error) {
		select {
		case <-done:
			return 0, net.ErrClosed
		default:
		}
		if len(packets) == 0 || len(packets) > passiveBatchSize || len(sizes) < len(packets) || len(endpoints) < len(packets) {
			return 0, errPassivePacket
		}
		return b.read(packets, sizes, endpoints, done)
	}
	return []conn.ReceiveFunc{receive}, b.port, nil
}

func (b *passiveBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.session != nil {
		close(b.session)
		b.session = nil
	}
	return nil
}

func (b *passiveBind) SetMark(mark uint32) error {
	if mark != 0 {
		return errPassiveMark
	}
	return nil
}

func (*passiveBind) BatchSize() int { return passiveBatchSize }

func (b *passiveBind) Send(bufs [][]byte, endpoint conn.Endpoint) error {
	ep, ok := endpoint.(*passiveEndpoint)
	if !ok || ep == nil {
		return conn.ErrWrongEndpointType
	}
	if len(bufs) == 0 || len(bufs) > passiveBatchSize {
		return errPassivePacket
	}
	for _, packet := range bufs {
		if len(packet) > passiveMaxDatagram {
			return errPassivePacket
		}
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.session == nil {
		return net.ErrClosed
	}
	// The host must cancel borrowed requests before Close joins in-flight sends.
	return b.send(bufs, ep.addr)
}

type passiveEndpoint struct{ addr netip.AddrPort }

var _ conn.Endpoint = (*passiveEndpoint)(nil)

func canonicalEndpoint(address netip.AddrPort) netip.AddrPort {
	return netip.AddrPortFrom(address.Addr().Unmap(), address.Port())
}

func (*passiveBind) ParseEndpoint(text string) (conn.Endpoint, error) {
	address, err := netip.ParseAddrPort(text)
	if err != nil {
		return nil, err
	}
	// The C ABI carries a numeric interface scope. Resolve named IPv6 zones only
	// when parsing configuration, never on the datagram fast path.
	if zone := address.Addr().Zone(); zone != "" {
		if _, err := strconv.ParseUint(zone, 10, 32); err != nil {
			iface, err := net.InterfaceByName(zone)
			if err != nil {
				return nil, err
			}
			address = netip.AddrPortFrom(address.Addr().WithZone(strconv.Itoa(iface.Index)), address.Port())
		}
	}
	return &passiveEndpoint{addr: canonicalEndpoint(address)}, nil
}

func (*passiveEndpoint) ClearSrc()             {}
func (*passiveEndpoint) SrcToString() string   { return "" }
func (*passiveEndpoint) SrcIP() netip.Addr     { return netip.Addr{} }
func (e *passiveEndpoint) DstToString() string { return e.addr.String() }
func (e *passiveEndpoint) DstIP() netip.Addr   { return e.addr.Addr() }
func (e *passiveEndpoint) DstToBytes() []byte  { b, _ := e.addr.MarshalBinary(); return b }
