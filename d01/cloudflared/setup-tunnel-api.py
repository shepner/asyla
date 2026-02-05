#!/usr/bin/env python3
"""
Full tunnel automation via Cloudflare API.
Creates or reuses a tunnel, pushes ingress from apps.yml, syncs DNS CNAMEs,
and creates/updates a Cloudflare Access application for hostnames with access: true.
Run from a machine with API credentials; copy the printed TUNNEL_TOKEN to d01 .env.

Ref: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/

Usage:
  ./setup-tunnel-api.py   (reads .env and apps.yml in script dir)
  Or set: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN
  Optional: TUNNEL_ID (reuse existing), TUNNEL_NAME (default: d01),
            CLOUDFLARE_ACCESS_APP_NAME (default: d01 media)

API token needs: Cloudflare Tunnel Edit, DNS Edit, Access: Apps and Policies Read/Write
(Identity Providers Read for Access). Uses only stdlib (urllib).
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
    """Parse apps.yml; return (domain, list of {hostname, service, port, access})."""
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
        access_m = re.search(r"access:\s*(true|false)", block, re.IGNORECASE)
        if hostname_m and service_m and port_m:
            hostname = hostname_m.group(1).strip()
            if "." not in hostname and domain:
                hostname = f"{hostname}.{domain}"
            access = access_m.group(1).lower() == "true" if access_m else True
            apps.append({
                "hostname": hostname,
                "service": service_m.group(1).strip(),
                "port": int(port_m.group(1)),
                "access": access,
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
    tunnel_token = None
    if not tunnel_id:
        # Prefer reusing existing tunnel with same name (avoids 409 "tunnel with this name exists")
        r = api_req("GET", f"/accounts/{account_id}/cfd_tunnel", token)
        if r.get("success"):
            for t in r.get("result", []):
                if t.get("name") == tunnel_name:
                    tunnel_id = t["id"]
                    print(f"Using existing tunnel '{tunnel_name}': {tunnel_id}")
                    break
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
            tunnel_token = result.get("token")
            if not tunnel_token and isinstance(result.get("credentials_file"), dict):
                tunnel_token = result["credentials_file"].get("TunnelSecret")
            if not tunnel_token:
                raise SystemExit("Create tunnel response had no token: " + json.dumps(result)[:200])
            print(f"Created tunnel: {tunnel_id}")
    else:
        print("Using existing tunnel (TUNNEL_ID):", tunnel_id)
    # Get token if we have tunnel_id but no token yet (reused by name or TUNNEL_ID)
    if tunnel_id and not tunnel_token:
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

    # 4) Cloudflare Access: protect hostnames with access: true (auth at Cloudflare)
    access_hostnames = [a["hostname"] for a in apps if a.get("access", True)]
    if access_hostnames:
        access_app_name = os.environ.get("CLOUDFLARE_ACCESS_APP_NAME", "d01 media").strip()
        r = api_req("GET", f"/accounts/{account_id}/access/identity_providers", token)
        if not r.get("success"):
            print("Access: list IdPs failed (token needs Access: Apps and Policies Read):", r.get("errors"), file=sys.stderr)
        else:
            idps = r.get("result", [])
            allowed_idps = [idp["id"] for idp in idps]
            # Find or create Access application
            r = api_req("GET", f"/accounts/{account_id}/access/apps", token)
            if not r.get("success"):
                print("Access: list apps failed:", r.get("errors"), file=sys.stderr)
            else:
                existing = next((app for app in r.get("result", []) if app.get("name") == access_app_name), None)
                app_id = None
                if existing:
                    app_id = existing["id"]
                    api_req("PUT", f"/accounts/{account_id}/access/apps/{app_id}", token, {
                        "name": access_app_name,
                        "type": "self_hosted",
                        "domain": access_hostnames[0],
                        "self_hosted_domains": access_hostnames,
                        "session_duration": "24h",
                        "allowed_idps": allowed_idps or existing.get("allowed_idps", []),
                    })
                    print(f"Access: updated application '{access_app_name}' ({len(access_hostnames)} hostnames).")
                else:
                    r2 = api_req("POST", f"/accounts/{account_id}/access/apps", token, {
                        "name": access_app_name,
                        "type": "self_hosted",
                        "domain": access_hostnames[0],
                        "self_hosted_domains": access_hostnames,
                        "session_duration": "24h",
                        "allowed_idps": allowed_idps if allowed_idps else None,
                    })
                    if not r2.get("success"):
                        print("Access: create app failed (token needs Access: Apps and Policies Write):", r2.get("errors"), file=sys.stderr)
                    else:
                        app_id = r2["result"]["id"]
                        print(f"Access: created application '{access_app_name}' ({len(access_hostnames)} hostnames).")
                # Ensure allow policy exists
                if app_id:
                    r3 = api_req("GET", f"/accounts/{account_id}/access/apps/{app_id}/policies", token)
                    if r3.get("success"):
                        policies = r3.get("result", [])
                        allow = next((p for p in policies if p.get("decision") == "allow"), None)
                        if not allow:
                            r4 = api_req("POST", f"/accounts/{account_id}/access/apps/{app_id}/policies", token, {
                                "name": "Allow authenticated",
                                "decision": "allow",
                                "include": [{"everyone": {}}],
                                "precedence": 1,
                            })
                            if r4.get("success"):
                                print("Access: added policy 'Allow authenticated' (everyone who logs in).")
                            else:
                                print("Access: add policy failed:", r4.get("errors"), file=sys.stderr)
                        else:
                            print("Access: allow policy already present.")

    print()
    print("Add this to ~/scripts/d01/cloudflared/.env on d01 (or your tunnel host):")
    print(f"TUNNEL_TOKEN={tunnel_token}")
    print()
    print("Then start the tunnel: ./start.sh  (or docker compose up -d)")


if __name__ == "__main__":
    main()
