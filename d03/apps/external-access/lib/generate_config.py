#!/usr/bin/env python3
"""Generate cloudflared config.yml from apps.yml (config-file tunnel mode)."""

import json
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
APPS_YAML = Path(os.environ.get("APPS_YAML", SCRIPT_DIR.parent / "apps.yml"))

_docker_dl = os.environ.get("DOCKER_DL", "/mnt/docker")
DATA_DIR = Path(os.environ.get("DATA_DIR", f"{_docker_dl}/cloudflared"))
ENV_FILE = DATA_DIR / ".env"
OUTPUT_CONFIG = DATA_DIR / "config.yml"
CREDENTIALS_FILE = DATA_DIR / "credentials.json"


def load_dotenv(path: Path) -> None:
    if not path.exists():
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def parse_apps_yml(path: Path) -> tuple[str, list[dict]]:
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


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    load_dotenv(ENV_FILE)

    tunnel_id = os.environ.get("TUNNEL_ID", "").strip()

    if not tunnel_id and CREDENTIALS_FILE.exists():
        try:
            creds = json.loads(CREDENTIALS_FILE.read_text())
            tunnel_id = creds.get("TunnelID", "").strip()
            if tunnel_id:
                print(f"[INFO] Using TUNNEL_ID from {CREDENTIALS_FILE}: {tunnel_id}")
        except Exception:
            pass

    if not tunnel_id:
        print(
            f"TUNNEL_ID not set. Set it in {ENV_FILE} or environment,\n"
            f"or place credentials.json in {DATA_DIR}.",
            file=sys.stderr,
        )
        sys.exit(1)

    if not APPS_YAML.exists():
        print(f"apps.yml not found: {APPS_YAML}", file=sys.stderr)
        sys.exit(1)

    domain, apps = parse_apps_yml(APPS_YAML)
    if not apps:
        print("No apps found in apps.yml.", file=sys.stderr)
        sys.exit(1)

    lines = [
        "# Generated from apps.yml — run generate-config.sh to regenerate",
        f"tunnel: {tunnel_id}",
        "credentials-file: /etc/cloudflared/credentials.json",
        "ingress:",
    ]
    for a in apps:
        lines.append(f"  - hostname: {a['hostname']}")
        lines.append(f"    service: http://{a['service']}:{a['port']}")
    lines.append("  - service: http_status:404")
    lines.append("")

    OUTPUT_CONFIG.write_text("\n".join(lines))
    print(f"Wrote {OUTPUT_CONFIG} with {len(apps)} hostnames.")


if __name__ == "__main__":
    main()
