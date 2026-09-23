#!/usr/bin/env python3

import socket
import socketserver
import threading

HOST = "127.0.0.1"
PORT = 18083
BUFFER_SIZE = 256 * 1024


def pump(src, dst, counters, key):
    try:
        while True:
            data = src.recv(BUFFER_SIZE)

            if not data:
                break

            dst.sendall(data)
            counters[key] += len(data)

    except (
        ConnectionResetError,
        BrokenPipeError,
        OSError,
    ):
        pass

    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class ConnectHandler(socketserver.StreamRequestHandler):
    def handle(self):
        request_line = self.rfile.readline(65536)

        if not request_line:
            return

        try:
            method, target, _ = (
                request_line
                .decode("iso-8859-1")
                .strip()
                .split(" ", 2)
            )
        except Exception:
            return

        while True:
            line = self.rfile.readline(65536)

            if line in (b"\r\n", b"\n", b""):
                break

        if method.upper() != "CONNECT":
            self.wfile.write(
                b"HTTP/1.1 405 Method Not Allowed\r\n"
                b"Connection: close\r\n"
                b"Content-Length: 0\r\n"
                b"\r\n"
            )
            self.wfile.flush()
            return

        if ":" in target:
            host, port = target.rsplit(":", 1)

            try:
                port = int(port)
            except ValueError:
                return
        else:
            host = target
            port = 443

        print(
            f"[CONNECT] {host}:{port}",
            flush=True,
        )

        try:
            upstream = socket.create_connection(
                (host, port),
                timeout=20,
            )

            # Timeout is only for establishing the connection.
            # Long downloads must not be killed by the proxy.
            upstream.settimeout(None)
            self.connection.settimeout(None)

        except Exception as exc:
            print(
                f"[CONNECT] OPEN FAILED "
                f"{host}:{port}: {exc}",
                flush=True,
            )

            self.wfile.write(
                b"HTTP/1.1 502 Bad Gateway\r\n"
                b"Connection: close\r\n"
                b"Content-Length: 0\r\n"
                b"\r\n"
            )
            self.wfile.flush()
            return

        self.wfile.write(
            b"HTTP/1.1 200 Connection Established\r\n"
            b"Proxy-Agent: LWCompat\r\n"
            b"\r\n"
        )
        self.wfile.flush()

        counters = {
            "up": 0,
            "down": 0,
        }

        upload_thread = threading.Thread(
            target=pump,
            args=(
                self.connection,
                upstream,
                counters,
                "up",
            ),
        )

        download_thread = threading.Thread(
            target=pump,
            args=(
                upstream,
                self.connection,
                counters,
                "down",
            ),
        )

        upload_thread.start()
        download_thread.start()

        upload_thread.join()
        download_thread.join()

        try:
            upstream.close()
        except OSError:
            pass

        print(
            f"[CONNECT] closed {host}:{port} "
            f"up={counters['up']} "
            f"down={counters['down']}",
            flush=True,
        )

    def log_message(self, *args):
        pass


class ConnectServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    with ConnectServer((HOST, PORT), ConnectHandler) as server:
        print(
            f"LWCompat HTTPS CONNECT proxy: "
            f"http://{HOST}:{PORT}",
            flush=True,
        )

        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
