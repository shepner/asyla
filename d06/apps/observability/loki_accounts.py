#!/usr/bin/env python3
"""Create asyla's own Loki accounts for d06 in OpenBao, once (loki-clients.toml beside this file).

Run on the workstation, from ~/local/asyla (asyla's hub token is the hub of the working directory):

    cd ~/local/asyla && python3 projects/asyla-hosts/d06/apps/observability/loki_accounts.py [--dry-run]

1. the tool: theOrg observability's scripts/loki_clients.py and openbao.py at deploy_role.py's
   TOOL_REV, `git show` from the local theOrg clone (deploy_role.THEORG_CLONE) into a private temp
   dir (0700, code only, removed after), after a fetch; TOOL_REV must be on the clone's
   origin/main. It runs with asyla's hub token, so it is code asyla read: loki_clients.py at
   f757911 (load_clients, kv_prefix, read_record, provision; read 2026-11-07, the same at b5bd228)
   and deploy_role.py's reviewed openbao.py.
2. asyla's hub OpenBao token, in this process (deploy_role.hub_sign_in: secrets-vault's
   openbao_client.token(), the hub of the working directory), set only in the tool's environment,
   as BAO_ROOT_TOKEN, the variable it reads (the name is the tool's; the token is the hub's, which
   may create and read under secret/hubs/asyla/own/ only: secrets-vault
   policies/hubs/hubs-asyla.hcl). OPENBAO_TOKEN, VAULT_TOKEN, BAO_TOKEN and any other copy are
   removed from it.
3. `loki_clients.py provision --registry loki-clients.toml` with LOKI_CLIENTS_KV_PREFIX
   secret/hubs/asyla/own/loki-clients: for each account with no record it writes one at
   <prefix>/<name>, username <name> and a password of secrets.token_urlsafe(32) made in that
   process, with KV v2 cas=0, so it never overwrites; an account that has one is left as it is.
   A second run changes nothing.

Never prints, logs or writes a password or the token: the tool prints `<name>: created` or
`<name>: exists`, and an error by its category (absent, refused, unreachable); its output is
passed on with the token masked all the same. --dry-run prints the plan from local files only:
no fetch, no vault.

Exit: 0 every account exists or was created; 1 otherwise (a `stopped:` line, or the tool's
`::error::` line).
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import deploy_role as dr  # noqa: E402

REGISTRY = HERE / "loki-clients.toml"
KV_PREFIX = f"{dr.KV}/own/loki-clients"     # secret/hubs/asyla/own/loki-clients
TOOL = ("loki_clients.py", "openbao.py")
TOOL_TIMEOUT = 120   # s: one read and at most one write per account
# Every variable a vault token could reach the tool under, besides the one set; and every
# LOKI_CLIENTS_* setting of the caller's (the tool reads LOKI_CLIENTS_REGISTRY and _KV_PREFIX).
DROP = set(dr.CALLER_TOKENS) | {"BAO_TOKEN", dr.VAULT_TOKEN_ENV, "OPENBAO_TOKEN_FILE"}
DROP_PREFIX = "LOKI_CLIENTS_"


def accounts(registry: Path = REGISTRY) -> list[str]:
    """The account names the registry lists (the tool checks the rest of each entry)."""
    try:
        data = tomllib.loads(registry.read_text())
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise dr.Stop(f"{registry.name}: {type(e).__name__}") from None
    names = sorted(data.get("clients") or {})
    if not names:
        raise dr.Stop(f"{registry.name}: no clients")
    return names


def check_rev() -> None:
    """After a fetch of origin: TOOL_REV is on the theOrg clone's origin/main and holds TOOL."""
    if dr.git("fetch", "--quiet", "origin", check=False).returncode != 0:
        print(f"  WARNING: git fetch origin in {dr.THEORG_CLONE} failed; using the clone as it is")
    rev = dr.TOOL_REV
    if dr.git("cat-file", "-e", f"{rev}^{{commit}}", check=False).returncode != 0:
        raise dr.Stop(f"TOOL_REV {rev[:12]} is not in {dr.THEORG_CLONE}; nothing written")
    if dr.git("merge-base", "--is-ancestor", rev, dr.MAIN, check=False).returncode != 0:
        raise dr.Stop(f"TOOL_REV {rev[:12]} is not on origin/main of {dr.THEORG_CLONE}; nothing written")
    for f in TOOL:
        if dr.git("cat-file", "-e", f"{rev}:scripts/{f}", check=False).returncode != 0:
            raise dr.Stop(f"scripts/{f} is not at TOOL_REV {rev[:12]} in {dr.THEORG_CLONE}; nothing written")


def unpack(into: Path) -> None:
    check_rev()
    for f in TOOL:
        (into / f).write_text(dr.git("show", f"{dr.TOOL_REV}:scripts/{f}").stdout)


def child_env(base: dict, token: str) -> dict:
    """The tool's environment: the caller's without any vault token or tool setting, with the hub
    token as BAO_ROOT_TOKEN and asyla's prefix."""
    env = {k: v for k, v in base.items() if k not in DROP and not k.startswith(DROP_PREFIX)}
    env["BAO_ROOT_TOKEN"] = token
    env["LOKI_CLIENTS_KV_PREFIX"] = KV_PREFIX
    return env


def tool_argv(tool_dir: Path, registry: Path = REGISTRY) -> list[str]:
    return [sys.executable, "-I", str(tool_dir / "loki_clients.py"), "provision", "--registry", str(registry)]


def show_plan(names: list[str]) -> None:
    print(f"loki accounts: {', '.join(names)} ({REGISTRY.name})")
    for n in names:
        print(f"  {KV_PREFIX}/{n}  (username {n}; password generated by the tool, never overwritten)")
    print(f"tool: theOrg observability scripts/{' and '.join(TOOL)} at TOOL_REV {dr.TOOL_REV[:12]} "
          f"from {dr.THEORG_CLONE}")
    print("token: asyla's hub token (the working directory's hub), as the tool's BAO_ROOT_TOKEN")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--dry-run", action="store_true", help="print the plan; no fetch, no vault")
    args = p.parse_args(argv)
    try:
        names = accounts()
        show_plan(names)
        if args.dry_run:
            print("DRY RUN: nothing fetched, nothing written")
            return 0
        tool_dir = Path(tempfile.mkdtemp(prefix="loki-accounts-"))   # 0700
        try:
            unpack(tool_dir)
            token = dr.hub_sign_in()
            try:
                proc = subprocess.run(tool_argv(tool_dir), env=child_env(os.environ, token),
                                      capture_output=True, text=True, timeout=TOOL_TIMEOUT)
            except subprocess.TimeoutExpired:
                raise dr.Stop(f"loki_clients.py provision: no end in {TOOL_TIMEOUT} s") from None
            except OSError as e:
                raise dr.Stop(f"cannot run loki_clients.py: {type(e).__name__}; nothing written") from None
        finally:
            shutil.rmtree(tool_dir, ignore_errors=True)
        out = dr.redact(proc.stdout + proc.stderr, [token]).rstrip()
        if out:
            print(out)
        if proc.returncode != 0:
            print(f"stopped: loki_clients.py provision exit {proc.returncode} (its line is above)")
            return 1
        print(f"loki accounts: {len(names)} stored under {KV_PREFIX}")
        return 0
    except dr.Stop as e:
        print(f"stopped: {e}")
        return 1
    except subprocess.CalledProcessError as e:   # git show (names only in its command)
        print(f"stopped: {' '.join(e.cmd)}: exit {e.returncode}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
