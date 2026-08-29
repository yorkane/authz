#!/usr/bin/env python3
import base64
import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse


USERS = {
    "remote@example.test": {
        "password": "remote123",
        "token": "remote-token-0000000000000001",
        "user": {
            "id": 42,
            "username": "remote_user",
            "roles": [{"name": "member"}, {"name": "operator"}, {"name": "ignored"}],
        },
    },
    "shadow@example.test": {
        "password": "remote123",
        "token": "shadow-token-0000000000000001",
        "user": {
            "id": 43,
            "username": "bob",
            "roles": [{"name": "viewer"}],
        },
    },
}

OAUTH_CODES = {}
OAUTH_ACCESS_TOKEN = "oauth-access-token-00000000000001"
OAUTH_TOKEN_REQUESTS = 0
NOCO_OAUTH_CODES = {}
NOCO_OAUTH_ACCESS_TOKEN = "noco-oauth-access-token-000000001"
NOCO_OAUTH_AUTHORIZATIONS = 0
DINGTALK_ACCESS_TOKEN = "dingtalk-access-token-0000000001"
WECHAT_ACCESS_TOKEN = "wechat-access-token-000000000001"
REGISTERED_CLIENTS = {}


class Handler(BaseHTTPRequestHandler):
    server_version = "MockNocoBase/1.0"

    def log_message(self, fmt, *args):
        sys.stdout.write((fmt % args) + "\n")
        sys.stdout.flush()

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        global OAUTH_TOKEN_REQUESTS
        parsed = urlparse(self.path)
        if parsed.path == "/api/oidcStates:create":
            if self.headers.get("Authorization") != "Bearer registration-api-key":
                self.send_json(401, {"errors": [{"message": "unauthorized"}]})
                return
            length = int(self.headers.get("Content-Length", "0"))
            try:
                values = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self.send_json(400, {"errors": [{"message": "bad json"}]})
                return
            payload = values.get("payload", {})
            client_id = values.get("oidcId")
            valid = values.get("model") == "Client" and client_id == payload.get("client_id")
            valid = valid and payload.get("token_endpoint_auth_method") == "client_secret_basic"
            valid = valid and payload.get("grant_types") == ["authorization_code"]
            valid = valid and payload.get("scope") == "openid profile email api"
            valid = valid and payload.get("redirect_uris") == [self.server.noco_redirect_uri]
            if not valid:
                self.send_json(400, {"errors": [{"message": "invalid client"}]})
                return
            REGISTERED_CLIENTS[client_id] = values
            self.send_json(200, {"data": {"id": len(REGISTERED_CLIENTS), "oidcId": client_id}})
            return
        if self.path == "/dingtalk/token":
            length = int(self.headers.get("Content-Length", "0"))
            try:
                values = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self.send_json(400, {"code": "invalid_request"})
                return
            if values != {
                "clientId": "ding-client",
                "clientSecret": "ding-secret",
                "code": "dingtalk-code-0001",
                "grantType": "authorization_code",
            }:
                self.send_json(400, {"code": "invalid_grant"})
                return
            self.send_json(200, {"accessToken": DINGTALK_ACCESS_TOKEN, "expireIn": 7200})
            return
        if self.path == "/oauth/token":
            OAUTH_TOKEN_REQUESTS += 1
            if OAUTH_TOKEN_REQUESTS == 1:
                self.close_connection = True
                self.connection.close()
                return
            length = int(self.headers.get("Content-Length", "0"))
            values = parse_qs(self.rfile.read(length).decode())
            code = values.get("code", [""])[0]
            verifier = values.get("code_verifier", [""])[0]
            expected = OAUTH_CODES.pop(code, None)
            challenge = base64.urlsafe_b64encode(
                hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            if not expected or challenge != expected or \
                    values.get("client_id", [""])[0] != "test-client":
                self.send_json(400, {"error": "invalid_grant"})
                return
            self.send_json(200, {
                "access_token": OAUTH_ACCESS_TOKEN,
                "token_type": "Bearer",
            })
            return
        if self.path == "/api/idpOAuth/token":
            length = int(self.headers.get("Content-Length", "0"))
            values = parse_qs(self.rfile.read(length).decode())
            code = values.get("code", [""])[0]
            verifier = values.get("code_verifier", [""])[0]
            expected = NOCO_OAUTH_CODES.pop(code, None)
            challenge = base64.urlsafe_b64encode(
                hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            expected_basic = "Basic " + base64.b64encode(b"noco-client:noco-secret").decode()
            if not expected or challenge != expected["challenge"] or \
                    self.headers.get("Authorization") != expected_basic or \
                    "client_id" in values or "client_secret" in values or "resource" in values or \
                    values.get("redirect_uri", [""])[0] != expected["redirect_uri"] or \
                    values.get("grant_type", [""])[0] != "authorization_code":
                self.send_json(400, {"error": "invalid_grant"})
                return
            self.send_json(200, {
                "access_token": NOCO_OAUTH_ACCESS_TOKEN,
                "token_type": "Bearer",
            })
            return
        if self.path != "/api/auth:signIn":
            self.send_json(404, {"errors": [{"message": "not found"}]})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            values = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_json(400, {"errors": [{"message": "bad json"}]})
            return
        user = USERS.get(values.get("account"))
        if not user or values.get("password") != user["password"]:
            self.send_json(401, {"errors": [{"message": "invalid credentials"}]})
            return
        self.send_json(200, {
            "data": {
                "token": user["token"],
                "user": {"id": user["user"]["id"], "username": user["user"]["username"]},
            }
        })

    def do_GET(self):
        global NOCO_OAUTH_AUTHORIZATIONS
        parsed = urlparse(self.path)
        if parsed.path == "/test/oauth-token-attempts":
            self.send_json(200, {"attempts": OAUTH_TOKEN_REQUESTS})
            return
        if parsed.path == "/api/oidcStates:list":
            if self.headers.get("Authorization") != "Bearer registration-api-key":
                self.send_json(401, {"errors": [{"message": "unauthorized"}]})
                return
            rows = [{"id": index, "oidcId": client_id}
                    for index, client_id in enumerate(REGISTERED_CLIENTS, 1)]
            self.send_json(200, {"data": rows})
            return
        if parsed.path == "/oauth/authorize":
            values = parse_qs(parsed.query)
            if values.get("response_type", [""])[0] != "code" or \
                    values.get("code_challenge_method", [""])[0] != "S256":
                self.send_json(400, {"error": "invalid_request"})
                return
            code = "oauth-code-0001"
            OAUTH_CODES[code] = values.get("code_challenge", [""])[0]
            redirect_uri = values.get("redirect_uri", [""])[0]
            separator = "&" if "?" in redirect_uri else "?"
            self.redirect(redirect_uri + separator + urlencode({
                "code": code,
                "state": values.get("state", [""])[0],
            }))
            return
        if parsed.path == "/api/idpOAuth/authorize":
            values = parse_qs(parsed.query)
            if values.get("response_type", [""])[0] != "code" or \
                    values.get("code_challenge_method", [""])[0] != "S256" or \
                    values.get("client_id", [""])[0] != "noco-client" or \
                    "resource" in values:
                self.send_json(400, {"error": "invalid_request"})
                return
            NOCO_OAUTH_AUTHORIZATIONS += 1
            code = f"noco-oauth-code-{NOCO_OAUTH_AUTHORIZATIONS:04d}"
            redirect_uri = values.get("redirect_uri", [""])[0]
            NOCO_OAUTH_CODES[code] = {
                "challenge": values.get("code_challenge", [""])[0],
                "redirect_uri": redirect_uri,
            }
            self.redirect(redirect_uri + "?" + urlencode({
                "code": code,
                "state": values.get("state", [""])[0],
                "iss": self.server.noco_issuer,
            }))
            return
        if parsed.path == "/dingtalk/authorize":
            values = parse_qs(parsed.query)
            if values.get("client_id", [""])[0] != "ding-client" or \
                    values.get("scope", [""])[0] != "openid":
                self.send_json(400, {"error": "invalid_request"})
                return
            redirect_uri = values.get("redirect_uri", [""])[0]
            self.redirect(redirect_uri + "?" + urlencode({
                "authCode": "dingtalk-code-0001",
                "state": values.get("state", [""])[0],
            }))
            return
        if parsed.path == "/dingtalk/userinfo":
            if self.headers.get("x-acs-dingtalk-access-token") != DINGTALK_ACCESS_TOKEN:
                self.send_json(401, {"code": "invalid_token"})
                return
            self.send_json(200, {
                "nick": "Ding User",
                "openId": "ding-open-id-88",
                "unionId": "ding-union-id-88",
            })
            return
        if parsed.path == "/wechat/authorize":
            values = parse_qs(parsed.query)
            if values.get("appid", [""])[0] != "wechat-app" or \
                    values.get("scope", [""])[0] != "snsapi_login":
                self.send_json(400, {"errcode": 40013})
                return
            redirect_uri = values.get("redirect_uri", [""])[0]
            self.redirect(redirect_uri + "?" + urlencode({
                "code": "wechat-code-0001",
                "state": values.get("state", [""])[0],
            }))
            return
        if parsed.path == "/wechat/token":
            values = parse_qs(parsed.query)
            if values.get("appid", [""])[0] != "wechat-app" or \
                    values.get("secret", [""])[0] != "wechat-secret" or \
                    values.get("code", [""])[0] != "wechat-code-0001":
                self.send_json(200, {"errcode": 40029})
                return
            self.send_json(200, {
                "access_token": WECHAT_ACCESS_TOKEN,
                "openid": "wechat-open-id-99",
                "unionid": "wechat-union-id-99",
            })
            return
        if parsed.path == "/wechat/userinfo":
            values = parse_qs(parsed.query)
            if values.get("access_token", [""])[0] != WECHAT_ACCESS_TOKEN or \
                    values.get("openid", [""])[0] != "wechat-open-id-99":
                self.send_json(200, {"errcode": 40003})
                return
            self.send_json(200, {
                "openid": "wechat-open-id-99",
                "unionid": "wechat-union-id-99",
                "nickname": "WeChat User",
            })
            return
        if parsed.path == "/oauth/userinfo":
            token = self.headers.get("Authorization", "").removeprefix("Bearer ")
            if token != OAUTH_ACCESS_TOKEN:
                self.send_json(401, {"error": "invalid_token"})
                return
            self.send_json(200, {
                "sub": "oauth-subject-77",
                "email": "oauth.user@example.test",
                "email_verified": True,
                "roles": ["employees"],
            })
            return
        if parsed.path == "/api/idpOAuth/me":
            token = self.headers.get("Authorization", "").removeprefix("Bearer ")
            if token != NOCO_OAUTH_ACCESS_TOKEN:
                self.send_json(401, {"error": "invalid_token"})
                return
            self.send_json(200, {
                "sub": "42",
                "preferred_username": "remote_user",
                "email": "remote@example.test",
                "email_verified": True,
            })
            return
        if self.path != "/api/auth:check":
            self.send_json(404, {"errors": [{"message": "not found"}]})
            return
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        if token == NOCO_OAUTH_ACCESS_TOKEN:
            self.send_json(401, {"errors": [{"message": "OAuth token is not a basic session"}]})
            return
        for user in USERS.values():
            if token == user["token"]:
                self.send_json(200, {"data": user["user"]})
                return
        self.send_json(401, {"errors": [{"message": "invalid token"}]})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    server.noco_issuer = f"http://127.0.0.1:{sys.argv[1]}/api"
    server.noco_redirect_uri = sys.argv[2] if len(sys.argv) > 2 else ""
    server.serve_forever()
