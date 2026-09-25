#!/usr/bin/env python3
"""A tiny in-memory stand-in for `bw serve`, covering only the endpoints
bw-agent calls. Used by tests/run.sh. Not a faithful Bitwarden emulation.

Usage: mock_bw_serve.py <port> <status>   (status: unlocked|locked|unauthenticated)
"""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1])
STATE = {"status": sys.argv[2] if len(sys.argv) > 2 else "unlocked"}

FOLDERS = [
    {"id": "f-agent", "name": "Claude"},
    {"id": "f-other", "name": "Personal"},
]
ITEMS = [
    {
        "id": "i-1",
        "name": "api-key",
        "folderId": "f-agent",
        "login": {"username": None, "password": "s3cr3t-value-WXYZ"},
        "fields": [{"name": "token", "value": "field-val-1234", "type": 1}],
    },
    {
        "id": "i-2",
        "name": "bank",
        "folderId": "f-other",
        "login": {"username": "me", "password": "must-never-be-visible"},
        "fields": [],
    },
]


def ok(data):
    return {"success": True, "data": data}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/status":
            return self.send(200, ok({"object": "template", "template": {"status": STATE["status"]}}))
        if STATE["status"] != "unlocked":
            return self.send(400, {"success": False, "message": "Vault is locked."})
        if u.path == "/list/object/folders":
            return self.send(200, ok({"object": "list", "data": FOLDERS}))
        if u.path == "/list/object/items":
            items = ITEMS
            if "folderid" in q:
                items = [i for i in items if i["folderId"] == q["folderid"][0]]
            if "search" in q:
                items = [i for i in items if q["search"][0].lower() in i["name"].lower()]
            return self.send(200, ok({"object": "list", "data": items}))
        if u.path.startswith("/object/password/"):
            iid = u.path.rsplit("/", 1)[1]
            for i in ITEMS:
                if i["id"] == iid:
                    return self.send(200, ok({"object": "string", "data": i["login"]["password"]}))
            return self.send(404, {"success": False})
        if u.path.startswith("/object/item/"):
            iid = u.path.rsplit("/", 1)[1]
            for i in ITEMS:
                if i["id"] == iid:
                    return self.send(200, ok(i))
            return self.send(404, {"success": False})
        self.send(404, {"success": False})

    def do_POST(self):
        u = urlparse(self.path)
        b = self.body()
        if u.path == "/unlock":
            STATE["status"] = "unlocked"
            return self.send(200, ok({"title": "Your vault is now unlocked!"}))
        if u.path == "/lock":
            STATE["status"] = "locked"
            return self.send(200, ok({}))
        if u.path == "/sync":
            return self.send(200, ok({}))
        if u.path == "/object/folder":
            f = {"id": "f-" + uuid.uuid4().hex[:6], "name": b["name"]}
            FOLDERS.append(f)
            return self.send(200, ok(f))
        if u.path == "/object/item":
            b["id"] = "i-" + uuid.uuid4().hex[:6]
            b.setdefault("fields", [])
            ITEMS.append(b)
            return self.send(200, ok(b))
        self.send(404, {"success": False})

    def do_PUT(self):
        u = urlparse(self.path)
        b = self.body()
        if u.path.startswith("/object/item/"):
            iid = u.path.rsplit("/", 1)[1]
            for idx, i in enumerate(ITEMS):
                if i["id"] == iid:
                    b["id"] = iid
                    b.setdefault("fields", [])
                    ITEMS[idx] = b
                    return self.send(200, ok(b))
        self.send(404, {"success": False})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
