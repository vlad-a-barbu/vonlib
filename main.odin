package main

import "core:log"
import "core:net"

Conn_State :: enum {
	Accepted,
	Receiving,
	Received,
	Sending,
	Sent
}

Client_Conn :: struct {
	socket: net.TCP_Socket,
	state: Conn_State,
	data: [dynamic]byte,
	sent: int,
}

create_client_conn :: proc(socket: net.TCP_Socket) -> Client_Conn {
	return Client_Conn { socket = socket, data = nil, state = Conn_State.Accepted }
}

destroy_client_conn :: proc(conn: ^Client_Conn) {
	if conn.data != nil do delete(conn.data);
	net.close(conn.socket)
}

recv_client_conn :: proc(conn: ^Client_Conn) -> net.Network_Error {
	buff := [0x100]byte{}
	n, err := net.recv_tcp(conn.socket, buff[:])
	switch err {
		case net.TCP_Recv_Error.Would_Block:
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
		case net.TCP_Send_Error.Would_Block:
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

handle_client_conn :: proc(conn: ^Client_Conn) -> (handled: bool, err: net.Network_Error) {
	switch conn.state {
		case Conn_State.Accepted:
			conn.state = Conn_State.Receiving
			fallthrough
		case Conn_State.Receiving:
			recv_client_conn(conn) or_return

		case Conn_State.Received:
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
	server_socket := net.listen_tcp(net.Endpoint{ address = net.IP4_Any, port = port }, backlog) or_return
	net.set_blocking(server_socket, false) or_return
	defer net.close(server_socket)
	log.infof("listening on port %d\n", port)

	client_conns := make([dynamic]Client_Conn, 0, backlog)
	defer { for &c in client_conns do destroy_client_conn(&c); delete(client_conns) }

	for {
		client_socket, _, err := net.accept_tcp(server_socket)
		switch err {
			case net.Accept_Error.Would_Block:
				// nop
			case nil:
				if err := net.set_blocking(client_socket, false); err != nil {
					log.errorf("set nonblocking client socket err: %v\n", err)
					continue
				}
				append(&client_conns, create_client_conn(client_socket))
			case:
				log.errorf("accept err: %v\n", err)
		}

		remove_idxs := [dynamic]int{}
		#reverse for &client_conn, i in client_conns {
			handled, err := handle_client_conn(&client_conn)
			if handled {
				append(&remove_idxs, i)
			}
			if err != nil {
				log.errorf("handle err: %v\n", err)
				append(&remove_idxs, i)
			}
		}
		for i in remove_idxs {
			destroy_client_conn(&client_conns[i])
			unordered_remove(&client_conns, i)
		}
	}
}

main :: proc() {
	cl := log.create_console_logger()
	defer log.destroy_console_logger(cl)
	context.logger = cl

	if err := serve(3000, 10); err != nil {
		log.errorf("serve err: %v\n", err)
	}
}
