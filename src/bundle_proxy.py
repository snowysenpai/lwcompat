#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.request
import urllib.error
import threading

ROUTES = [
    (
        "CDN",
        18080,
        "https://lastwar-cdn.akamaized.net/hotupdate",
    ),
    (
        "API",
        18081,
        "https://lastwar-serverlist-cf.lastwarapp.net",
    ),
]


def make_handler(label, upstream):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.forward(send_body=True)

        def do_HEAD(self):
            self.forward(send_body=False)

        def forward(self, send_body):
            url = upstream.rstrip("/") + "/" + self.path.lstrip("/")

            print(f"\n[{label}] {self.command} {self.path}", flush=True)
            print(f"[{label}] -> {url}", flush=True)

            headers = {
                "User-Agent": self.headers.get("User-Agent", "LastWarLauncher"),
                "Accept": self.headers.get("Accept", "*/*"),
                "Accept-Encoding": "identity",
                "Connection": "close",
            }

            for header in (
                "Range",
                "If-Range",
                "If-None-Match",
                "If-Modified-Since",
            ):
                value = self.headers.get(header)
                if value:
                    headers[header] = value

            request = urllib.request.Request(
                url,
                headers=headers,
                method=self.command,
            )

            try:
                response = urllib.request.urlopen(request, timeout=120)
            except urllib.error.HTTPError as exc:
                response = exc
            except Exception as exc:
                print(f"[{label}] !! upstream error: {exc}", flush=True)
                body = str(exc).encode("utf-8", errors="replace")
                self.send_response(502)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                if send_body:
                    self.wfile.write(body)
                self.close_connection = True
                return

            status = getattr(response, "status", None) or response.code
            print(
                f"[{label}] <- HTTP {status} "
                f"len={response.headers.get('Content-Length')} "
                f"range={response.headers.get('Content-Range')}",
                flush=True,
            )

            self.send_response(status)

            for header in (
                "Content-Type",
                "Content-Length",
                "Content-Range",
                "Accept-Ranges",
                "ETag",
                "Last-Modified",
                "Content-Disposition",
            ):
                value = response.headers.get(header)
                if value is not None:
                    self.send_header(header, value)

            self.send_header("Connection", "close")
            self.end_headers()

            total = 0
            if send_body:
                try:
                    while True:
                        chunk = response.read(256 * 1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        total += len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    print(
                        f"[{label}] !! client disconnected after {total} bytes",
                        flush=True,
                    )

            response.close()
            print(f"[{label}] streamed={total}", flush=True)
            self.close_connection = True

        def log_message(self, *args):
            pass

    return Handler


servers = []

for label, port, upstream in ROUTES:
    server = ThreadingHTTPServer(
        ("127.0.0.1", port),
        make_handler(label, upstream),
    )
    servers.append(server)

    threading.Thread(
        target=server.serve_forever,
        daemon=True,
    ).start()

    print(f"{label}: http://127.0.0.1:{port} -> {upstream}", flush=True)

print("\nLWCompat dual native bridge READY", flush=True)

try:
    threading.Event().wait()
except KeyboardInterrupt:
    pass
finally:
    for server in servers:
        server.shutdown()
