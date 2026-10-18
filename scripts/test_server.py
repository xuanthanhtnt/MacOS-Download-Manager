#!/usr/bin/env python3
"""Small HTTP server used by the integration tests.

  /files/<name>    supports Range requests (206)
  /slow/<name>     same, but throttled (to test pause/resume)
  /norange/<name>  ignores Range and always returns 200
  /busy/<name>     Range support, but answers 503 when more than 2 requests run at once
  /hls/<name>      static HLS files

Usage: test_server.py <fixtures-dir> <port>
"""
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = sys.argv[1]
PORT = int(sys.argv[2])
busy_lock = threading.Lock()
busy_count = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.handle_request(head=True)

    def do_GET(self):
        self.handle_request(head=False)

    def handle_request(self, head):
        global busy_count
        path = self.path.split("?")[0]
        if path == "/page":
            # Test page with one download link: /page?href=<url>
            from urllib.parse import parse_qs, urlparse
            href = parse_qs(urlparse(self.path).query).get("href", ["/files/big.bin"])[0]
            body = f'<!doctype html><html><body><a id="dl" href="{href}">download</a></body></html>'.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return
        if path == "/watch":
            # Imitates a YouTube watch page, including its Trusted Types policy (blocks innerHTML).
            body = b'<!doctype html><html><head><title>Test video - YouTube</title></head><body><div id="player">video</div></body></html>'
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Security-Policy", "require-trusted-types-for 'script'")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return
        if path.startswith("/redirect/"):
            # Like go.microsoft.com/fwlink: an address without the file name that redirects to the file
            self.send_response(302)
            self.send_header("Location", "/files/" + os.path.basename(path))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        parts = path.strip("/").split("/", 1)
        if len(parts) != 2:
            return self.send_error(404)
        mode, name = parts
        folder = "hls" if mode == "hls" else "files"
        file_path = os.path.join(ROOT, folder, os.path.basename(name))
        if not os.path.isfile(file_path):
            return self.send_error(404)

        if mode == "busy":
            with busy_lock:
                if busy_count >= 2:
                    self.send_response(503)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                busy_count += 1
        try:
            self.serve(file_path, mode, head)
        finally:
            if mode == "busy":
                with busy_lock:
                    busy_count -= 1

    def serve(self, file_path, mode, head):
        size = os.path.getsize(file_path)
        start, end = 0, size - 1
        partial = False
        range_header = self.headers.get("Range")
        if range_header and mode != "norange" and range_header.startswith("bytes="):
            a, _, b = range_header[6:].partition("-")
            start = int(a) if a else 0
            end = int(b) if b else size - 1
            end = min(end, size - 1)
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            partial = True

        length = end - start + 1
        self.send_response(206 if partial else 200)
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        if mode != "norange":
            self.send_header("Accept-Ranges", "bytes")
        ctype = "application/vnd.apple.mpegurl" if file_path.endswith(".m3u8") else "application/octet-stream"
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.end_headers()
        if head:
            return
        try:
            with open(file_path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(16384, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
                    if mode == "slow":
                        time.sleep(0.03)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print(f"test server on 127.0.0.1:{PORT}", flush=True)
    server.serve_forever()
