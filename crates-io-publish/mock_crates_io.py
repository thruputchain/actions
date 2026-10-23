#!/usr/bin/env python3
"""Mock crates.io for test_crates_io_publish.sh: the API, sparse index,
downloads, trusted publishing endpoints and GitHub's OIDC token endpoint.

Usage: mock_crates_io.py <port-file>. Listens on a free local port and
writes it to <port-file>. The cargo stub uploads through /_test/publish;
the tests seed and inspect state through the other /_test/ endpoints.
Bootstrap token: "boot". Anything else is rejected.
"""

import base64
import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BOOTSTRAP = "boot"

# canonical crate key (lower case, _ as -) -> {name, versions, configs}
crates = {}
# (name, version) -> the .crate file uploaded for it
files = {}
# (name, version) -> its trustpub_data: None when published with an API token
provenance = {}
# GitHub OIDC claims the job's tokens carry
claims = {"repository": "o/r", "repository_owner_id": "1",
          "workflow_ref": "o/r/.github/workflows/publish.yml@refs/heads/main",
          "environment": None}
oidc_tokens = {}  # crates.io trusted publishing token -> allowed crate keys
rate_limited = set()  # crate keys whose next new-crate publish gets a 429
log = []


def key(name):
    return name.lower().replace("_", "-")


def jwt():
    payload = {k: v for k, v in claims.items() if v is not None}
    enc = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"h.{enc}.s"


def config_matches(config):
    owner, repo = claims["repository"].split("/")
    workflow = claims["workflow_ref"].split("@")[0].rsplit("/", 1)[1]
    env = claims["environment"]
    if (config["repository_owner"].lower(), config["repository_name"].lower()) != (owner, repo):
        return False
    if config["workflow_filename"] != workflow:
        return False
    if config.get("environment") is None:
        return True
    return env is not None and config["environment"].lower() == env.lower()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def error(self, code, detail):
        self.reply(code, {"errors": [{"detail": detail}]})

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        auth = self.headers.get("Authorization")
        log.append(["GET", url.path, auth])
        if url.path == "/oidc":
            if auth != "Bearer reqtok" or query.get("audience") != ["crates.io"]:
                return self.error(401, "bad OIDC request")
            return self.reply(200, {"value": jwt()})
        if url.path.startswith("/api/v1/crates/") and url.path.count("/") == 5:
            _, _, _, _, name, vers = url.path.split("/")
            crate = crates.get(key(name))
            if not crate or vers not in crate["versions"]:
                return self.error(404, "not found")
            return self.reply(200, {"version": {"num": vers,
                                                "trustpub_data": provenance.get((crate["name"], vers))}})
        if url.path.startswith("/api/v1/crates/"):
            crate = crates.get(key(url.path.rsplit("/", 1)[1]))
            if not crate:
                return self.error(404, "not found")
            return self.reply(200, {"crate": {"name": crate["name"]}})
        if url.path.startswith("/index/"):
            name = url.path.rsplit("/", 1)[1]
            crate = crates.get(key(name))
            if not crate or crate["name"].lower() != name:
                return self.error(404, "not found")
            lines = "".join(json.dumps({"name": crate["name"], "vers": v,
                                        "cksum": hashlib.sha256(files.get((crate["name"], v), b"")).hexdigest()})
                            + "\n" for v in sorted(crate["versions"]))
            body = lines.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return None
        if url.path.startswith("/dl/"):
            _, _, name, file = url.path.split("/")
            data = files.get((name, file.removeprefix(name + "-").removesuffix(".crate")))
            if data is None:
                return self.error(404, "not found")
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return None
        if url.path == "/api/v1/trusted_publishing/github_configs":
            if auth != BOOTSTRAP:
                return self.error(403, "bad token")
            crate = crates.get(key(query["crate"][0]))
            return self.reply(200, {"github_configs": crate["configs"] if crate else [],
                                    "meta": {"total": 0, "next_page": None}})
        if url.path == "/_test/state":
            return self.reply(200, {"crates": {k: {**v, "versions": sorted(v["versions"])}
                                               for k, v in crates.items()},
                                    "oidc_tokens": oidc_tokens, "log": log})
        return self.error(404, "no route")

    def do_POST(self):
        url = urlparse(self.path)
        auth = self.headers.get("Authorization")
        body = self.read_json()
        log.append(["POST", url.path, auth, body])
        if url.path == "/api/v1/trusted_publishing/tokens":
            if auth is not None or body.get("jwt") != jwt():
                return self.error(400, "Failed to decode JWT")
            allowed = [k for k, c in crates.items() if any(config_matches(x) for x in c["configs"])]
            if not allowed:
                return self.error(400, "No Trusted Publishing config found")
            token = f"oidc-{len(log)}"
            oidc_tokens[token] = allowed
            return self.reply(200, {"token": token})
        if url.path == "/api/v1/trusted_publishing/github_configs":
            if auth != BOOTSTRAP:
                return self.error(403, "bad token")
            config = body["github_config"]
            crates[key(config["crate"])]["configs"].append(config)
            return self.reply(200, {"github_config": config})
        if url.path == "/_test/publish":
            k = key(body["name"])
            token = body["token"]
            if k in rate_limited and k not in crates:
                rate_limited.discard(k)
                return self.error(429, "You have published too many new crates")
            if token == BOOTSTRAP:
                crates.setdefault(k, {"name": body["name"], "versions": set(), "configs": []})
            elif k not in oidc_tokens.get(token, []):
                return self.error(403, "this token can't publish " + body["name"])
            crates[k]["versions"].add(body["vers"])
            files[(body["name"], body["vers"])] = base64.b64decode(body["crate"])
            provenance[(body["name"], body["vers"])] = None if token == BOOTSTRAP else {
                "provider": "github", "repository": claims["repository"],
                "run_id": "1", "sha": body["sha"]}
            return self.reply(200, {})
        if url.path == "/_test/owner":
            if auth != BOOTSTRAP:
                return self.error(403, "bad token")
            return self.reply(200, {})
        if url.path == "/_test/seed":
            for name, versions in body.get("crates", {}).items():
                crates[key(name)] = {"name": name, "versions": set(versions), "configs": []}
            for config in body.get("configs", []):
                crates[key(config["crate"])]["configs"].append(config)
            for name, versions in body.get("files", {}).items():
                for vers, data in versions.items():
                    files[(name, vers)] = base64.b64decode(data)
            for name, versions in body.get("provenance", {}).items():
                for vers, data in versions.items():
                    provenance[(name, vers)] = data
            for name in body.get("rate_limited", []):
                rate_limited.add(key(name))
            claims.update(body.get("claims", {}))
            return self.reply(200, {})
        if url.path == "/_test/reset":
            crates.clear()
            files.clear()
            provenance.clear()
            oidc_tokens.clear()
            rate_limited.clear()
            log.clear()
            claims["environment"] = None
            return self.reply(200, {})
        return self.error(404, "no route")

    def do_DELETE(self):
        auth = self.headers.get("Authorization") or ""
        log.append(["DELETE", self.path, auth])
        oidc_tokens.pop(auth.removeprefix("Bearer "), None)
        self.reply(204)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
