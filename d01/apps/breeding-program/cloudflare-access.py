#!/usr/bin/env python3
"""Cloudflare side of breeding-program.asyla.org (run on d01; stdlib only).

  cloudflare-access.py --email a@x --email b@y         ensure the dedicated Access app + email policy; print AUD
  cloudflare-access.py --email ... --publish           also add the tunnel ingress rule and the DNS CNAME
  cloudflare-access.py --status                        show what exists; change nothing

Credentials: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN and TUNNEL_TOKEN from
/mnt/docker/cloudflared/.env (override with CF_ENV_FILE). Nothing secret is printed.

Unlike ../cloudflared/setup-tunnel-api.py this never replaces the tunnel's ingress list: it inserts one
rule before the catch-all. The app is its own Access application (access: false in ../cloudflared/apps.yml
keeps it out of the shared "d01 media" app). Publishing refuses unless the Access app and its allow
policy already exist, so the hostname is never reachable without sign-in.
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

HOSTNAME = "breeding-program.asyla.org"
SERVICE = "http://breeding-program:8080"
APP_NAME = "breeding-program"
POLICY_NAME = "Allowed emails"
API = "https://api.cloudflare.com/client/v4"


def load_env(path: Path) -> dict[str, str]:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


class CF:
    def __init__(self, token: str):
        self.token = token

    def req(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(
            API + path,
            data=data,
            method=method,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                out = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            raise SystemExit(f"[ERROR] {method} {path}: HTTP {e.code} {e.read().decode()[:400]}") from None
        if not out.get("success", False):
            raise SystemExit(f"[ERROR] {method} {path}: {out.get('errors')}")
        return out


def tunnel_id_from_token(tunnel_token: str) -> str:
    # The connector token is base64 JSON {"a": account, "t": tunnel id, "s": secret}; use only "t".
    padded = tunnel_token + "=" * (-len(tunnel_token) % 4)
    return json.loads(base64.b64decode(padded))["t"]


def find_app(cf: CF, account: str) -> dict | None:
    apps = cf.req("GET", f"/accounts/{account}/access/apps")["result"]
    return next((a for a in apps if a.get("domain") == HOSTNAME or a.get("name") == APP_NAME), None)


def allow_policy(cf: CF, account: str, app_id: str) -> dict | None:
    policies = cf.req("GET", f"/accounts/{account}/access/apps/{app_id}/policies")["result"]
    return next((p for p in policies if p.get("decision") == "allow"), None)


def policy_emails(policy: dict) -> list[str]:
    return sorted(i["email"]["email"] for i in policy.get("include", []) if "email" in i)


def ensure_access(cf: CF, account: str, emails: list[str]) -> dict:
    idps = cf.req("GET", f"/accounts/{account}/access/identity_providers")["result"]
    otp = [i["id"] for i in idps if i.get("type") == "onetimepin"]
    if not otp:
        raise SystemExit("[ERROR] no one-time PIN identity provider in this account")
    payload = {
        "name": APP_NAME,
        "type": "self_hosted",
        "domain": HOSTNAME,
        "session_duration": "24h",
        "allowed_idps": otp,
        "auto_redirect_to_identity": True,
        "app_launcher_visible": False,
    }
    app = find_app(cf, account)
    if app:
        app = cf.req("PUT", f"/accounts/{account}/access/apps/{app['id']}", payload)["result"]
        print(f"[INFO] Access app '{APP_NAME}' updated")
    else:
        app = cf.req("POST", f"/accounts/{account}/access/apps", payload)["result"]
        print(f"[INFO] Access app '{APP_NAME}' created")
    policy = {
        "name": POLICY_NAME,
        "decision": "allow",
        "include": [{"email": {"email": e}} for e in emails],
        "precedence": 1,
    }
    existing = allow_policy(cf, account, app["id"])
    if existing:
        cf.req("PUT", f"/accounts/{account}/access/apps/{app['id']}/policies/{existing['id']}", policy)
    else:
        cf.req("POST", f"/accounts/{account}/access/apps/{app['id']}/policies", policy)
    print(f"[INFO] policy '{POLICY_NAME}': {', '.join(emails)}")
    return app


def ingress_state(cf: CF, account: str, tunnel: str) -> tuple[dict, list[dict]]:
    cfg = cf.req("GET", f"/accounts/{account}/cfd_tunnel/{tunnel}/configurations")["result"].get("config") or {}
    return cfg, cfg.get("ingress") or []


def publish(cf: CF, account: str, zone: str, tunnel: str) -> None:
    app = find_app(cf, account)
    if not app or not allow_policy(cf, account, app["id"]):
        raise SystemExit("[ERROR] refusing to publish: the Access app and its allow policy must exist first")
    cfg, ingress = ingress_state(cf, account, tunnel)
    rule = {"hostname": HOSTNAME, "service": SERVICE}
    if any(r.get("hostname") == HOSTNAME for r in ingress):
        ingress = [rule if r.get("hostname") == HOSTNAME else r for r in ingress]
    else:
        catch_all = [r for r in ingress if "hostname" not in r] or [{"service": "http_status:404"}]
        ingress = [r for r in ingress if "hostname" in r] + [rule] + catch_all[-1:]
    cfg["ingress"] = ingress
    cf.req("PUT", f"/accounts/{account}/cfd_tunnel/{tunnel}/configurations", {"config": cfg})
    print(f"[INFO] tunnel ingress: {HOSTNAME} -> {SERVICE} ({len(ingress) - 1} hostnames total)")
    target = f"{tunnel}.cfargotunnel.com"
    recs = cf.req("GET", f"/zones/{zone}/dns_records?name={HOSTNAME}")["result"]
    body = {"type": "CNAME", "name": HOSTNAME, "content": target, "proxied": True}
    if recs:
        if recs[0]["type"] != "CNAME":
            raise SystemExit(f"[ERROR] {HOSTNAME} already has a {recs[0]['type']} record; resolve by hand")
        cf.req("PATCH", f"/zones/{zone}/dns_records/{recs[0]['id']}", body)
    else:
        cf.req("POST", f"/zones/{zone}/dns_records", body)
    print(f"[INFO] DNS: {HOSTNAME} CNAME -> tunnel (proxied)")


def status(cf: CF, account: str, zone: str, tunnel: str) -> None:
    app = find_app(cf, account)
    if app:
        pol = allow_policy(cf, account, app["id"])
        print(f"[INFO] Access app '{app['name']}' domain={app['domain']} aud={app['aud']}")
        print(f"[INFO] allow policy emails: {policy_emails(pol) if pol else 'NONE'}")
    else:
        print("[INFO] Access app: none")
    _, ingress = ingress_state(cf, account, tunnel)
    print(f"[INFO] tunnel ingress has {HOSTNAME}: {any(r.get('hostname') == HOSTNAME for r in ingress)}")
    recs = cf.req("GET", f"/zones/{zone}/dns_records?name={HOSTNAME}")["result"]
    print(f"[INFO] DNS records for {HOSTNAME}: {[(r['type'], r['proxied']) for r in recs]}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--email", action="append", default=[], help="allowed email (repeat)")
    ap.add_argument("--publish", action="store_true", help="add ingress rule + DNS (after Access exists)")
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args()

    env = load_env(Path(os.environ.get("CF_ENV_FILE", "/mnt/docker/cloudflared/.env")))
    account, zone = env["CLOUDFLARE_ACCOUNT_ID"], env["CLOUDFLARE_ZONE_ID"]
    tunnel = env.get("TUNNEL_ID") or tunnel_id_from_token(env["TUNNEL_TOKEN"])
    cf = CF(env["CLOUDFLARE_API_TOKEN"])

    if args.status:
        status(cf, account, zone, tunnel)
        return
    if not args.email:
        ap.error("--email is required (the full allow list; it replaces the policy's list)")
    app = ensure_access(cf, account, sorted(set(args.email)))
    print(f"CF_ACCESS_AUD={app['aud']}")
    if args.publish:
        publish(cf, account, zone, tunnel)


if __name__ == "__main__":
    sys.exit(main())
