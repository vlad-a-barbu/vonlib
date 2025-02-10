package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"

tracking_allocator_destroy :: proc(track: ^mem.Tracking_Allocator) {
	if len(track.allocation_map) > 0 {
		fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
		for _, entry in track.allocation_map {
			fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
		}
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
		for entry in track.bad_free_array {
			fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
		}
	}
	mem.tracking_allocator_destroy(track)
}

when ODIN_OS == .Windows {
	Would_Block :: net.TCP_Recv_Error.Would_Block
} else when ODIN_OS == .Darwin {
	Would_Block :: net.TCP_Recv_Error.Timeout
} else {
	#panic("os not supported")
}

Conn_State :: enum {
	Accepted,
	Receiving,
	Received,
	Sending,
	Sent,
}

Client_Conn :: struct {
	socket: net.TCP_Socket,
	state:  Conn_State,
	data:   [dynamic]byte,
	sent:   int,
}

stop_condition :: proc(data: []byte) -> bool {
	when ODIN_DEBUG {
		req := strings.clone_from_bytes(data)
		defer delete(req)
		return strings.trim_space(req) == "die"
	}
	return false
}

create_client_conn :: proc(socket: net.TCP_Socket) -> Client_Conn {
	return Client_Conn{socket = socket, data = nil, state = Conn_State.Accepted}
}

destroy_client_conn :: proc(conn: ^Client_Conn) {
	if conn.data != nil do delete(conn.data)
	net.close(conn.socket)
}

recv_client_conn :: proc(conn: ^Client_Conn) -> net.Network_Error {
	buff := [0x100]byte{}
	n, err := net.recv_tcp(conn.socket, buff[:])

	switch err {
	case Would_Block:
		return nil
	case nil:
		if n == 0 {
			conn.state = Conn_State.Received
		} else {
			append(&conn.data, ..buff[:n])
		}
		return nil
	case:
		return err
	}
}

send_client_conn :: proc(conn: ^Client_Conn) -> net.Network_Error {
	n, err := net.send_tcp(conn.socket, conn.data[conn.sent:])
	switch err {
	case Would_Block:
		return nil
	case nil:
		conn.sent += n
		if conn.sent == len(conn.data) {
			conn.state = Conn_State.Sent
		}
		return nil
	case:
		return err
	}
}

handle_client_conn :: proc(
	conn: ^Client_Conn,
) -> (
	stop: bool,
	handled: bool,
	err: net.Network_Error,
) {
	switch conn.state {
	case Conn_State.Accepted:
		conn.state = Conn_State.Receiving
		fallthrough
	case Conn_State.Receiving:
		recv_client_conn(conn) or_return

	case Conn_State.Received:
		if stop_condition(conn.data[:]) {
			stop = true
			return
		}
		conn.state = Conn_State.Sending
		fallthrough
	case Conn_State.Sending:
		send_client_conn(conn) or_return

	case Conn_State.Sent:
		handled = true
	}
	return
}

serve :: proc(port: int, backlog: int) -> (err: net.Network_Error) {
	server_socket := net.listen_tcp(
		net.Endpoint{address = net.IP4_Any, port = port},
		backlog,
	) or_return
	net.set_blocking(server_socket, false) or_return
	defer net.close(server_socket)
	log.infof("listening on port %d", port)

	client_conns := make([dynamic]Client_Conn, 0, backlog)
	defer {for &c in client_conns do destroy_client_conn(&c);delete(client_conns)}

	accept_loop: for {
		client_socket, _, err := net.accept_tcp(server_socket)
		switch err {
		case net.Accept_Error.Would_Block:
		// nop
		case nil:
			if err := net.set_blocking(client_socket, false); err != nil {
				log.errorf("set nonblocking client socket err: %v", err)
				continue
			}
			append(&client_conns, create_client_conn(client_socket))
		case:
			log.errorf("accept err: %v", err)
		}

		remove_idxs := make([dynamic]int, 0, len(client_conns))
		defer delete(remove_idxs)
		#reverse for &client_conn, i in client_conns {
			stop, handled, err := handle_client_conn(&client_conn)
			if stop {
				break accept_loop
			}
			if handled {
				append(&remove_idxs, i)
			}
			if err != nil {
				log.errorf("handle err: %v", err)
				append(&remove_idxs, i)
			}
		}
		for i in remove_idxs {
			destroy_client_conn(&client_conns[i])
			unordered_remove(&client_conns, i)
		}
	}

	return
}

main :: proc() {
	lowest := log.Level.Info
	when ODIN_DEBUG {
		lowest = .Debug
	}
	cl := log.create_console_logger(lowest)
	defer log.destroy_console_logger(cl)
	context.logger = cl

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer tracking_allocator_destroy(&track)

	log.debug("debugging...")
	if err := serve(4200, 10); err != nil {
		log.errorf("serve err: %v", err)
	}
}
