#!/usr/bin/env python3

import select
import socket
import socketserver


HOST = "127.0.0.1"
PORT = 18083

HEADER_LIMIT = 64 * 1024
READ_SIZE = 1024 * 1024
MAX_BUFFER = 8 * 1024 * 1024


def tune(sock):
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except OSError:
        pass

    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass

    for option in (socket.SO_RCVBUF, socket.SO_SNDBUF):
        try:
            sock.setsockopt(
                socket.SOL_SOCKET,
                option,
                4 * 1024 * 1024,
            )
        except OSError:
            pass


def read_connect_request(sock):
    data = bytearray()

    while b"\r\n\r\n" not in data:
        chunk = sock.recv(16 * 1024)

        if not chunk:
            return None, b""

        data.extend(chunk)

        if len(data) > HEADER_LIMIT:
            raise RuntimeError("CONNECT header too large")

    header, remainder = bytes(data).split(
        b"\r\n\r\n",
        1,
    )

    lines = header.split(b"\r\n")

    if not lines:
        return None, remainder

    try:
        method, target, _version = (
            lines[0]
            .decode("iso-8859-1")
            .split(" ", 2)
        )
    except Exception:
        return None, remainder

    if method.upper() != "CONNECT":
        return None, remainder

    return target, remainder


def split_target(target):
    if ":" not in target:
        return target, 443

    host, port_text = target.rsplit(":", 1)

    return host, int(port_text)


def relay(client, upstream, initial_upstream=b""):
    client.setblocking(False)
    upstream.setblocking(False)

    to_upstream = bytearray(initial_upstream)
    to_client = bytearray()

    client_eof = False
    upstream_eof = False

    client_write_closed = False
    upstream_write_closed = False

    uploaded = len(initial_upstream)
    downloaded = 0

    while True:
        readers = []
        writers = []

        if not client_eof and len(to_upstream) < MAX_BUFFER:
            readers.append(client)

        if not upstream_eof and len(to_client) < MAX_BUFFER:
            readers.append(upstream)

        if to_upstream:
            writers.append(upstream)

        if to_client:
            writers.append(client)

        if (
            client_eof
            and upstream_eof
            and not to_upstream
            and not to_client
        ):
            break

        if not readers and not writers:
            break

        try:
            readable, writable, exceptional = select.select(
                readers,
                writers,
                [client, upstream],
                5.0,
            )
        except (OSError, ValueError):
            break

        if exceptional:
            break

        if client in readable:
            try:
                chunk = client.recv(READ_SIZE)
            except BlockingIOError:
                chunk = None
            except OSError:
                chunk = b""

            if chunk:
                to_upstream.extend(chunk)
                uploaded += len(chunk)
            elif chunk == b"":
                client_eof = True

        if upstream in readable:
            try:
                chunk = upstream.recv(READ_SIZE)
            except BlockingIOError:
                chunk = None
            except OSError:
                chunk = b""

            if chunk:
                to_client.extend(chunk)
                downloaded += len(chunk)
            elif chunk == b"":
                upstream_eof = True

        if upstream in writable and to_upstream:
            try:
                sent = upstream.send(to_upstream)

                if sent > 0:
                    del to_upstream[:sent]
            except BlockingIOError:
                pass
            except OSError:
                client_eof = True
                to_upstream.clear()

        if client in writable and to_client:
            try:
                sent = client.send(to_client)

                if sent > 0:
                    del to_client[:sent]
            except BlockingIOError:
                pass
            except OSError:
                upstream_eof = True
                to_client.clear()

        if (
            client_eof
            and not to_upstream
            and not upstream_write_closed
        ):
            try:
                upstream.shutdown(socket.SHUT_WR)
            except OSError:
                pass

            upstream_write_closed = True

        if (
            upstream_eof
            and not to_client
            and not client_write_closed
        ):
            try:
                client.shutdown(socket.SHUT_WR)
            except OSError:
                pass

            client_write_closed = True

    return uploaded, downloaded


class ConnectHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        tune(client)

        try:
            target, remainder = read_connect_request(client)
        except Exception as exc:
            print(
                f"[CONNECT] malformed request: {exc}",
                flush=True,
            )
            return

        if not target:
            try:
                client.sendall(
                    b"HTTP/1.1 405 Method Not Allowed\r\n"
                    b"Connection: close\r\n"
                    b"Content-Length: 0\r\n"
                    b"\r\n"
                )
            except OSError:
                pass

            return

        try:
            host, port = split_target(target)
        except Exception:
            return

        print(
            f"[CONNECT] {host}:{port}",
            flush=True,
        )

        try:
            upstream = socket.create_connection(
                (host, port),
                timeout=20,
            )

            tune(upstream)

        except Exception as exc:
            print(
                f"[CONNECT] OPEN FAILED {host}:{port}: {exc}",
                flush=True,
            )

            try:
                client.sendall(
                    b"HTTP/1.1 502 Bad Gateway\r\n"
                    b"Connection: close\r\n"
                    b"Content-Length: 0\r\n"
                    b"\r\n"
                )
            except OSError:
                pass

            return

        try:
            client.sendall(
                b"HTTP/1.1 200 Connection Established\r\n"
                b"Proxy-Agent: LWCompat\r\n"
                b"\r\n"
            )

            uploaded, downloaded = relay(
                client,
                upstream,
                remainder,
            )

        except Exception as exc:
            print(
                f"[CONNECT] relay error {host}:{port}: {exc}",
                flush=True,
            )

            uploaded = 0
            downloaded = 0

        finally:
            try:
                upstream.close()
            except OSError:
                pass

        print(
            f"[CONNECT] closed {host}:{port} "
            f"up={uploaded} down={downloaded}",
            flush=True,
        )


class ConnectServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 128


def main():
    with ConnectServer(
        (HOST, PORT),
        ConnectHandler,
    ) as server:

        print(
            f"LWCompat HTTPS CONNECT proxy: "
            f"http://{HOST}:{PORT}",
            flush=True,
        )

        try:
            server.serve_forever(
                poll_interval=0.1
            )
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
