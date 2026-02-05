#!/usr/bin/env python3
"""
Full tunnel automation via Cloudflare API.
Creates or reuses a tunnel, pushes ingress from apps.yml, and syncs DNS CNAMEs.
Run from a machine with API credentials; copy the printed TUNNEL_TOKEN to d01 .env.

Ref: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/

Usage:
  ./setup-tunnel-api.py   (reads .env and apps.yml in script dir)
  Or set: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN
  Optional: TUNNEL_ID (reuse existing), TUNNEL_NAME (default: d01)

Requires: requests (pip install requests) or use only stdlib (urllib).
"""
import json
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
APPS_YAML = SCRIPT_DIR / "apps.yml"
ENV_FILE = SCRIPT_DIR / ".env"
API_BASE = "https://api.cloudflare.com/client/v4"


def load_dotenv(path: Path) -> None:
    """Load KEY=VALUE from .env into os.environ."""
    if not path.exists():
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def parse_apps_yml(path: Path) -> tuple[str, list[dict]]:
    """Parse apps.yml; return (domain, list of {hostname, service, port})."""
    text = path.read_text()
    domain = ""
    apps = []
    m = re.search(r"^domain:\s*(\S+)", text, re.MULTILINE)
    if m:
        domain = m.group(1).strip()
    for block in re.split(r"\n\s*-\s+app:", text):
        hostname_m = re.search(r"hostname:\s*(\S+)", block)
        service_m = re.search(r"service:\s*(\S+)", block)
        port_m = re.search(r"port:\s*(\d+)", block)
        if hostname_m and service_m and port_m:
            hostname = hostname_m.group(1).strip()
            if "." not in hostname and domain:
                hostname = f"{hostname}.{domain}"
            apps.append({
                "hostname": hostname,
                "service": service_m.group(1).strip(),
                "port": int(port_m.group(1)),
            })
    return domain, apps


def api_req(method: str, path: str, token: str, json_body: dict | None = None) -> dict:
    """Call Cloudflare API; path is relative (e.g. /accounts/xx/cfd_tunnel)."""
    try:
        import urllib.request
        import urllib.error
    except ImportError:
        import urllib.request
        import urllib.error
    url = API_BASE + path
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    data = json.dumps(json_body).encode() if json_body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        raise SystemExit(f"API {method} {path}: {e.code} {body}")


def main() -> None:
    load_dotenv(ENV_FILE)
    account_id = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip()
    zone_id = os.environ.get("CLOUDFLARE_ZONE_ID", "").strip()
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()
    tunnel_id = os.environ.get("TUNNEL_ID", "").strip()
    tunnel_name = os.environ.get("TUNNEL_NAME", "d01").strip()

    if not account_id or not token:
        print("Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN (and CLOUDFLARE_ZONE_ID for DNS).", file=sys.stderr)
        sys.exit(1)
    if not APPS_YAML.exists():
        print(f"apps.yml not found: {APPS_YAML}", file=sys.stderr)
        sys.exit(1)

    domain, apps = parse_apps_yml(APPS_YAML)
    if not apps:
        print("No apps in apps.yml.", file=sys.stderr)
        sys.exit(1)

    # 1) Create tunnel or get token for existing
    if not tunnel_id:
        print("Creating tunnel...")
        r = api_req("POST", f"/accounts/{account_id}/cfd_tunnel", token, {
            "name": tunnel_name,
            "config_src": "cloudflare",
        })
        if not r.get("success"):
            raise SystemExit("Create tunnel failed: " + json.dumps(r.get("errors", r)))
        result = r["result"]
        tunnel_id = result["id"]
        # Token may be at top level or in credentials_file (API doc shows result.token)
        tunnel_token = result.get("token")
        if not tunnel_token and isinstance(result.get("credentials_file"), dict):
            tunnel_token = result["credentials_file"].get("TunnelSecret")
        if not tunnel_token:
            raise SystemExit("Create tunnel response had no token: " + json.dumps(result)[:200])
        print(f"Created tunnel: {tunnel_id}")
    else:
        print("Using existing tunnel:", tunnel_id)
        r = api_req("GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/token", token)
        if not r.get("success"):
            raise SystemExit("Get tunnel token failed: " + json.dumps(r.get("errors", r)))
        tunnel_token = r.get("result")
        if isinstance(tunnel_token, dict):
            tunnel_token = tunnel_token.get("token") or tunnel_token.get("value")
        elif not isinstance(tunnel_token, str):
            tunnel_token = None
        if not tunnel_token:
            raise SystemExit("No token in response: " + json.dumps(r))

    # 2) Build and push ingress config
    ingress = []
    for a in apps:
        ingress.append({
            "hostname": a["hostname"],
            "service": f"http://{a['service']}:{a['port']}",
        })
    ingress.append({"service": "http_status:404"})

    r = api_req("PUT", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations", token, {
        "config": {"ingress": ingress},
    })
    if not r.get("success"):
        raise SystemExit("Put tunnel config failed: " + json.dumps(r.get("errors", r)))
    print(f"Updated tunnel config ({len(apps)} hostnames).")

    # 3) DNS CNAMEs (if zone_id set)
    cname_target = f"{tunnel_id}.cfargotunnel.com"
    if zone_id:
        for a in apps:
            hostname = a["hostname"]
            # List existing CNAME for this hostname (name can be FQDN or subdomain per zone)
            r = api_req("GET", f"/zones/{zone_id}/dns_records?type=CNAME&name={hostname}", token)
            if not r.get("success"):
                print(f"  DNS list failed for {hostname}: {r.get('errors')}", file=sys.stderr)
                continue
            records = r.get("result", [])
            if records:
                rec = records[0]
                if rec.get("content") != cname_target or rec.get("proxied") is not True:
                    api_req("PATCH", f"/zones/{zone_id}/dns_records/{rec['id']}", token, {
                        "content": cname_target,
                        "proxied": True,
                    })
                    print(f"  Updated DNS: {hostname} -> {cname_target}")
            else:
                api_req("POST", f"/zones/{zone_id}/dns_records", token, {
                    "type": "CNAME",
                    "name": hostname,
                    "content": cname_target,
                    "proxied": True,
                })
                print(f"  Created DNS: {hostname} -> {cname_target}")
        print("DNS records synced.")
    else:
        print("CLOUDFLARE_ZONE_ID not set; skipping DNS. Create CNAMEs manually to <tunnel_id>.cfargotunnel.com")

    print()
    print("Add this to ~/scripts/d01/cloudflared/.env on d01 (or your tunnel host):")
    print(f"TUNNEL_TOKEN={tunnel_token}")
    print()
    print("Then start the tunnel: ./start.sh  (or docker compose up -d)")


if __name__ == "__main__":
    main()
