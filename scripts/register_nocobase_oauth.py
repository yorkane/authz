#!/usr/bin/env python3
import argparse
import hashlib
import json
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def parse_env(path):
    values = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def update_env(path, updates):
    lines = path.read_text().splitlines()
    remaining = dict(updates)
    output = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in remaining:
                output.append(f"{key}={remaining.pop(key)}")
                continue
        output.append(line)
    if remaining:
        if output and output[-1] != "":
            output.append("")
        output.append("# NocoBase OAuth Client（由 scripts/register_nocobase_oauth.py 管理）")
        output.extend(f"{key}={value}" for key, value in remaining.items())
    path.write_text("\n".join(output) + "\n")
    path.chmod(0o600)


def request_json(url, api_key, method="GET", payload=None):
    body = None
    headers = {"Accept": "application/json", "Authorization": f"Bearer {api_key}"}
    if payload is not None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"NocoBase API returned HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise RuntimeError(f"NocoBase API request failed: {error}") from error


def require_url(value, name, allow_http):
    parsed = urllib.parse.urlsplit(value)
    allowed = {"https"} | ({"http"} if allow_http else set())
    if parsed.scheme not in allowed or not parsed.netloc or parsed.path not in ("", "/") or \
            parsed.query or parsed.fragment:
        raise ValueError(f"{name} must be an {'HTTP(S)' if allow_http else 'HTTPS'} origin URL")
    return value.rstrip("/")


def main():
    parser = argparse.ArgumentParser(description="Register the Authz Gateway as a NocoBase OAuth client")
    parser.add_argument("--env-file", default=".env")
    parser.add_argument(
        "--host-url",
        help="公网网关 Origin；会写入 AUTHZ_HOST_URL 并生成 callback URI",
    )
    parser.add_argument(
        "--new-client",
        action="store_true",
        help="按 Host URL 生成新的 Client ID，避免复用旧回调配置",
    )
    parser.add_argument("--allow-http", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    env_path = Path(args.env_file)
    if not env_path.is_file():
        raise ValueError(f"environment file not found: {env_path}")
    values = parse_env(env_path)
    noco_url = require_url(values.get("AUTHZ_NOCO_URL", ""), "AUTHZ_NOCO_URL", args.allow_http)
    host_url = require_url(
        args.host_url or values.get("AUTHZ_HOST_URL", ""),
        "AUTHZ_HOST_URL",
        args.allow_http,
    )
    api_key = values.get("AUTHZ_NOCO_API_KEY", "")
    if not api_key:
        raise ValueError("AUTHZ_NOCO_API_KEY is required")

    redirect_uri = host_url + "/_authz/oauth/callback"
    client_id = values.get("AUTHZ_NOCO_OAUTH_CLIENT_ID") or (
        "openresty-authz-" + hashlib.sha256(host_url.encode()).hexdigest()[:12]
    )
    if args.new_client:
        client_id = "openresty-authz-" + hashlib.sha256(host_url.encode()).hexdigest()[:12]
    configured_secret = values.get("AUTHZ_NOCO_OAUTH_CLIENT_SECRET", "")

    query = urllib.parse.urlencode({
        "filter": json.dumps({"model": "Client"}, separators=(",", ":")),
        "fields": "id,oidcId",
    })
    result = request_json(f"{noco_url}/api/oidcStates:list?{query}", api_key)
    rows = result.get("data") if isinstance(result, dict) else None
    if not isinstance(rows, list):
        raise RuntimeError("NocoBase client list returned an invalid response")
    exists = any(isinstance(row, dict) and row.get("oidcId") == client_id for row in rows)

    if exists and not configured_secret:
        raise RuntimeError(
            f"client {client_id!r} already exists but AUTHZ_NOCO_OAUTH_CLIENT_SECRET is unavailable"
        )

    client_secret = configured_secret or secrets.token_urlsafe(48)
    if not exists:
        request_json(f"{noco_url}/api/oidcStates:create", api_key, "POST", {
            "model": "Client",
            "oidcId": client_id,
            "payload": {
                "client_id": client_id,
                "client_name": "OpenResty Authz Gateway",
                "client_secret": client_secret,
                "redirect_uris": [redirect_uri],
                "grant_types": ["authorization_code"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "client_secret_basic",
                "scope": "openid profile email api",
                "application_type": "web",
                "subject_type": "public",
                "id_token_signed_response_alg": "RS256",
                "client_id_issued_at": int(time.time()),
                "client_secret_expires_at": 0,
                "post_logout_redirect_uris": [],
                "require_auth_time": False,
                "require_pushed_authorization_requests": False,
                "dpop_bound_access_tokens": False,
            },
        })

    update_env(env_path, {
        "AUTHZ_HOST_URL": host_url,
        "AUTHZ_NOCO_OAUTH_ENABLED": "true",
        "AUTHZ_NOCO_OAUTH_CLIENT_ID": client_id,
        "AUTHZ_NOCO_OAUTH_CLIENT_SECRET": client_secret,
        "AUTHZ_NOCO_OAUTH_REDIRECT_URI": redirect_uri,
    })
    action = "reused" if exists else "registered"
    print(f"NocoBase OAuth client {action}: {client_id}")
    print(f"Redirect URI: {redirect_uri}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
