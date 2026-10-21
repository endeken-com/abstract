#!/usr/bin/env python3
"""Preview Abstract's plugins and the plugin kit in a browser, outside the app.

    python3 docs/plugin-kit/preview.py            # then open http://localhost:8765/

Serves the bundled plugins under /plugins/, the kit under /_abstract/ (as
Abstract does), and a stand-in for the host (stub.js) that hands each page
the colours of ?theme=graphite|paper|ink at document start and a made-up
snapshot. Nothing here is used by the app itself.
"""
import http.server
import os
import sys
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
KIT = os.path.join(REPO, "Abstract", "Resources", "PluginKit")
PLUGINS = os.path.join(REPO, "Abstract", "Resources", "Plugins")
TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".js": "text/javascript; charset=utf-8", ".json": "application/json"}
STUB = b'<script src="/__preview/tokens.js"></script><script src="/__preview/fixtures.js"></script>' \
       b'<script src="/__preview/stub.js"></script>'


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            path = "/__preview/index.html"
        if path.startswith("/_abstract/"):
            file = os.path.join(KIT, path[len("/_abstract/"):])
        elif path.startswith("/plugins/"):
            file = os.path.join(PLUGINS, path[len("/plugins/"):])
        elif path.startswith("/__preview/"):
            file = os.path.join(HERE, path[len("/__preview/"):])
        else:
            file = ""
        file = os.path.realpath(file)
        if not file or not os.path.isfile(file) or not file.startswith((KIT, PLUGINS, HERE)):
            self.send_error(404)
            return
        with open(file, "rb") as f:
            data = f.read()
        ext = os.path.splitext(file)[1]
        if ext == ".html" and file.startswith(PLUGINS):
            data = data.replace(b"<head>", b"<head>" + STUB, 1)
        self.send_response(200)
        self.send_header("Content-Type", TYPES.get(ext, "application/octet-stream"))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"http://localhost:{port}/")
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
