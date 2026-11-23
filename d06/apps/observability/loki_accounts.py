#!/usr/bin/env python3
"""Create asyla's own gateway accounts for d06 in OpenBao, once (the registries beside this file).

Run on the workstation, from ~/local/asyla (asyla's hub token is the hub of the working directory):

    cd ~/local/asyla && python3 projects/asyla-hosts/d06/apps/observability/loki_accounts.py [verify] [--registry R] [--dry-run]

--registry names the gateway's registry, each with its own file and its own prefix under
secret/hubs/asyla/own/ (REGISTRIES), so no password is shared across gateways: loki
(loki-clients.toml), prometheus-write (prometheus-write-clients.toml, asyla #1268 item 3),
pushgateway (pushgateway-clients.toml, item 4), or all (provision's default: the three in that
order, one tool and one sign-in; the first that fails stops the rest). verify takes one of loki
(its default), pushgateway or prometheus-write; see "verify" below.

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
3. per registry, `loki_clients.py provision --registry <its toml>` with LOKI_CLIENTS_KV_PREFIX its
   prefix (loki: secret/hubs/asyla/own/loki-clients): for each account with no record it writes one at
   <prefix>/<name>, username <name> and a password of secrets.token_urlsafe(32) made in that
   process, with KV v2 cas=0, so it never overwrites; an account that has one is left as it is.
   A second run changes nothing.

`verify` runs, in step 3, `loki_clients.py verify --registry loki-clients.toml --url
https://loki.asyla.org --ca-volume ''` instead, with the same tool, prefix and token: d06's
loki-gateway end to end through d06's Caddy (README.md, Secrets). It reads the two check accounts'
passwords (observability-check-push and observability-check-query; the tool stops when either is
missing) and asks each check with `docker run curlimages/curl` on the workstation, the account in
curl's config on stdin. `''` means no --cacert: curl trusts its image's own store, which takes
loki.asyla.org's Let's Encrypt certificate (loki_clients.py curl() at TOOL_REV f757911: no
--cacert and no volume when the CA volume is empty). Writes nothing to OpenBao.

`verify --registry pushgateway` and `verify --registry prometheus-write` (asyla #1268) check the
two metrics gateways here, not with loki_clients.py (its verify knows Loki's routes alone): one
account each (METRICS: deploy-all at https://pushgateway.asyla.org, host-agent-ws02 at
https://prometheus-write.asyla.org), its record read from the registry's prefix with the hub token
through the tool's openbao.py (kv_read, TLS verified), in this process. Each check (METRIC_CHECKS,
from theOrg loki-gateway gateway.go at 28b23389, ServeHTTP: /ready needs no account; pushgateway
mode admits PUT, POST and DELETE on /metrics/job/... only, remote-write mode POST /api/v1/write
only, and any other path is 404 before an account is asked) is a `docker run curlimages/curl` on
the workstation with verified TLS on the image's own trust store (no --cacert, never -k), the
account in curl's config on stdin (`-K -`): never on argv, in the environment or in a file. The
pushgateway's pushed group is deleted again. Until the ingest Prometheus behind prometheus-write
is deployed, its account's write and its /ready are 502 (said in the output); 400 or 204 for the
write, 200 for /ready, mean the upstream answered. Writes nothing to OpenBao.

Never prints, logs or writes a password or the token: the tool prints `<name>: created` or
`<name>: exists` (verify: one `ok` or `FAIL` line per check), and an error by its category
(absent, refused, unreachable); its output is passed on with the token masked all the same.
--dry-run prints the plan from local files only: no fetch, no vault, no curl.

Exit: 0 every account exists or was created (verify: every check passed); 1 otherwise (a
`stopped:` line, or the tool's `::error::` or FAIL lines).
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import deploy_role as dr  # noqa: E402

# Each gateway's registry and the prefix its records go under (compose.yml LOKI_CLIENTS_KV_PREFIX
# of that gateway; deploy_role.py IDENTITIES reads the same files), in provision order.
REGISTRIES = {
    "loki": (HERE / "loki-clients.toml", f"{dr.KV}/own/loki-clients"),
    "prometheus-write": (HERE / "prometheus-write-clients.toml", f"{dr.KV}/own/prometheus-write-clients"),
    "pushgateway": (HERE / "pushgateway-clients.toml", f"{dr.KV}/own/pushgateway-clients"),
}
REGISTRY, KV_PREFIX = REGISTRIES["loki"]     # Loki's: secret/hubs/asyla/own/loki-clients
TOOL = ("loki_clients.py", "openbao.py")
TOOL_TIMEOUT = 120   # s: one read and at most one write per account
VERIFY_TIMEOUT = 900   # s: 11 curl containers (each up to 120 s in the tool), then up to 10 read-backs
GATEWAY_URL = "https://loki.asyla.org"   # d06's Caddy in front of loki-gateway (internal-access hosts/d06)
CHECK_ACCOUNTS = ("observability-check-push", "observability-check-query")   # the tool's, at f757911
# Every variable a vault token could reach the tool under, besides the one set; and every
# LOKI_CLIENTS_* setting of the caller's (the tool reads LOKI_CLIENTS_REGISTRY and _KV_PREFIX).
DROP = set(dr.CALLER_TOKENS) | {"BAO_TOKEN", dr.VAULT_TOKEN_ENV, "OPENBAO_TOKEN_FILE"}
DROP_PREFIX = "LOKI_CLIENTS_"

# The metrics gateways verify checks here (asyla #1268): its d06 Caddy URL and the one account it
# signs in with, read from the registry's prefix (REGISTRIES).
METRICS = {
    "pushgateway": ("https://pushgateway.asyla.org", "deploy-all"),
    "prometheus-write": ("https://prometheus-write.asyla.org", "host-agent-ws02"),
}
PUSH_JOB = "/metrics/job/asyla_verify"
PUSH_BODY = "asyla_verify_push 1\n"
TEXT_FORMAT = ("Content-Type: text/plain; version=0.0.4",)
REMOTE_WRITE = ("Content-Type: application/x-protobuf", "Content-Encoding: snappy",
                "X-Prometheus-Remote-Write-Version: 0.1.0")
DOWN = "the ingest Prometheus is not deployed yet, so the gateway has no upstream"
UP = "the upstream answered"
MIN_PASSWORD_LEN = 32   # theOrg loki_clients.py check_value at f757911
CURL_TIMEOUT = 60       # s per curl container (curl itself stops at 20 s)
# curlimages/curl 8.23.0, pinned by its index digest (docker buildx imagetools inspect
# curlimages/curl:8.23.0, 2026-11-22; the same as :latest that day).
CURL_IMAGE = ("curlimages/curl:8.23.0"
              "@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93")
# Per gateway, in order: (label, method, path, who, body, headers, {wanted status: note}); who is
# None (no account), "wrong" (the account with a wrong password) or "account". gateway.go at
# 28b23389: /ready is open; an admitted path asks for an account (401); GET /metrics is not an
# admitted path in pushgateway mode, so 404 comes before the account is asked.
METRIC_CHECKS = {
    "pushgateway": [
        ("/ready, no account", "GET", "/ready", None, None, (), {200: ""}),
        ("push, no account", "PUT", PUSH_JOB, None, PUSH_BODY, TEXT_FORMAT, {401: ""}),
        ("push, wrong password", "PUT", PUSH_JOB, "wrong", PUSH_BODY, TEXT_FORMAT, {401: ""}),
        ("push, {account}", "PUT", PUSH_JOB, "account", PUSH_BODY, TEXT_FORMAT, {200: "", 202: ""}),
        ("delete, {account} (cleanup)", "DELETE", PUSH_JOB, "account", None, (), {202: ""}),
        ("/metrics, {account} (not an admitted path)", "GET", "/metrics", "account", None, (), {404: ""}),
    ],
    # 502 is accepted while the ingest Prometheus is not deployed; tighten the account's write
    # (to 400 or 204) and /ready (to 200) when it ships (theorg #1285).
    "prometheus-write": [
        ("write, no account", "POST", "/api/v1/write", None, "", REMOTE_WRITE, {401: ""}),
        ("write, wrong password", "POST", "/api/v1/write", "wrong", "", REMOTE_WRITE, {401: ""}),
        ("write, {account}, empty body", "POST", "/api/v1/write", "account", "", REMOTE_WRITE,
         {502: DOWN, 400: UP, 204: UP}),
        ("/ready, no account", "GET", "/ready", None, None, (), {502: DOWN, 200: UP}),
    ],
}


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


def child_env(base: dict, token: str, prefix: str = KV_PREFIX) -> dict:
    """The tool's environment: the caller's without any vault token or tool setting, with the hub
    token as BAO_ROOT_TOKEN and the registry's prefix (Loki's by default)."""
    env = {k: v for k, v in base.items() if k not in DROP and not k.startswith(DROP_PREFIX)}
    env["BAO_ROOT_TOKEN"] = token
    env["LOKI_CLIENTS_KV_PREFIX"] = prefix
    return env


def chosen(registry: str | None, mode: str) -> list[str]:
    """The registries to run, by name: provision takes one or all (the default); verify one
    gateway (loki by default)."""
    if mode == "verify":
        if registry == "all":
            raise dr.Stop("verify takes one gateway: --registry loki, pushgateway or prometheus-write")
        return [registry or "loki"]
    return list(REGISTRIES) if registry in (None, "all") else [registry]


def tool_argv(tool_dir: Path, registry: Path = REGISTRY, mode: str = "provision") -> list[str]:
    argv = [sys.executable, "-I", str(tool_dir / "loki_clients.py"), mode, "--registry", str(registry)]
    if mode == "verify":
        argv += ["--url", GATEWAY_URL, "--ca-volume", ""]
    return argv


def curl_argv(url: str, method: str = "GET", body: str | None = None, headers: tuple = ()) -> list[str]:
    """A curl container's command line: no account and no password on it (curl reads its config,
    the account, from stdin: -K -); TLS verified on the image's own trust store (no --cacert)."""
    argv = ["docker", "run", "--rm", "-i", "--cpus", "0.5", "--memory", "64m", CURL_IMAGE,
            "-sS", "--max-time", "20", "-K", "-", "-X", method, "-w", "%{http_code}", "-o", "/dev/null"]
    for h in headers:
        argv += ["-H", h]
    if body is not None:
        argv += ["--data-binary", body]
    return [*argv, url]


def curl_env(base: dict) -> dict:
    """The docker CLI's environment: the caller's without any vault token (DROP, and the tool's
    BAO_ROOT_TOKEN) or LOKI_CLIENTS_* setting."""
    return {k: v for k, v in base.items()
            if k not in DROP and k != "BAO_ROOT_TOKEN" and not k.startswith(DROP_PREFIX)}


def curl(url: str, user: tuple[str, str] | None = None, method: str = "GET", body: str | None = None,
         headers: tuple = ()) -> int:
    """The HTTP status (0 when curl got none), the account in curl's config on stdin."""
    config = f'user = "{user[0]}:{user[1]}"\n' if user else ""
    try:
        proc = subprocess.run(curl_argv(url, method, body, headers), input=config, capture_output=True,
                              text=True, timeout=CURL_TIMEOUT, env=curl_env(os.environ))
    except (subprocess.TimeoutExpired, OSError):
        return 0
    try:
        return int(proc.stdout.strip())
    except ValueError:
        return 0


def load_openbao(tool_dir: Path):
    """The tool's openbao.py, unpacked in tool_dir, as a module of this process."""
    spec = importlib.util.spec_from_file_location("openbao", tool_dir / "openbao.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_password(bao, token: str, registry: str) -> str:
    """The metrics gateway's verify account's password, read with the hub token; Stop naming the
    record and what is wrong (never the value)."""
    name = METRICS[registry][1]
    record = f"{REGISTRIES[registry][1]}/{name}"
    try:
        data = bao.kv_read(record, token=token)
    except bao.OpenBaoError as e:
        hint = "; run loki_accounts.py --registry " + registry if e.category == "absent" else ""
        raise dr.Stop(f"{record}: {e.category}{hint}") from None
    pw = data.get("password")
    if data.get("username") != name or not isinstance(pw, str) or not pw:
        raise dr.Stop(f"{record}: the record has no password, or its username is not {name}")
    if (len(pw) < MIN_PASSWORD_LEN or '"' in pw or "\\" in pw
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in pw)):
        raise dr.Stop(f"{record}: the password is not a secrets.token_urlsafe(32) value (not shown)")
    return pw


def verify_metrics(registry: str, password: str) -> bool:
    """Every METRIC_CHECKS line of the gateway, one `ok` or `FAIL` line each; True when all pass."""
    base, name = METRICS[registry]
    # The wrong password is a fresh random value, nothing derived from the account's.
    users = {None: None, "wrong": (name, secrets.token_urlsafe(32)), "account": (name, password)}
    checks = METRIC_CHECKS[registry]
    ran: set[int] = set()
    ok = True

    def run(i: int) -> bool:
        label, method, path, who, body, headers, want = checks[i]
        ran.add(i)
        got = curl(base + path, users[who], method, body, headers)
        good = got in want
        note = want[got] if good else ""
        print(f"{'ok' if good else 'FAIL':4} {label.format(account=name)}: {method} {path} HTTP {got} "
              f"(want {' or '.join(map(str, want))})" + (f"; {note}" if note else ""))
        return good

    try:
        for i in range(len(checks)):
            ok &= run(i)
    finally:   # the pushed group is deleted again whatever happened before its turn
        for i, c in enumerate(checks):
            if c[1] == "DELETE" and i not in ran:
                ok &= run(i)
    return ok


def show_plan(names: list[str], mode: str = "provision", registry: str = "loki") -> None:
    path, prefix = REGISTRIES[registry]
    print(f"{registry} accounts: {', '.join(names)} ({path.name})")
    if mode == "verify" and registry in METRICS:
        base, name = METRICS[registry]
        if name not in names:
            raise dr.Stop(f"verify needs the account {name}; missing from {path.name}")
        print(f"verify: {base} with {name}, its password read from {prefix}/{name}; each check a "
              "`docker run curlimages/curl` on this workstation, TLS verified on curl's own trust "
              "store (no --cacert), the account in curl's config on stdin")
        for label, method, url_path, _, _, _, want in METRIC_CHECKS[registry]:
            notes = "; ".join(f"{c}: {n}" for c, n in want.items() if n)
            print(f"  {label.format(account=name)}: {method} {url_path}, want {' or '.join(map(str, want))}"
                  + (f" ({notes})" if notes else ""))
    elif mode == "verify":
        missing = [n for n in CHECK_ACCOUNTS if n not in names]
        if missing:
            raise dr.Stop(f"verify needs the accounts {' and '.join(CHECK_ACCOUNTS)}; "
                          f"missing from {REGISTRY.name}: {', '.join(missing)}")
        print(f"verify: loki_clients.py verify --url {GATEWAY_URL} --ca-volume '' (no --cacert: "
              f"curl's own trust store), with {' and '.join(CHECK_ACCOUNTS)} read from {KV_PREFIX}; "
              "each check a `docker run curlimages/curl` on this workstation")
    else:
        for n in names:
            print(f"  {prefix}/{n}  (username {n}; password generated by the tool, never overwritten)")


def show_tool(metrics: bool = False) -> None:
    used = "openbao.py (kv_read, in this process)" if metrics else " and ".join(TOOL)
    print(f"tool: theOrg observability scripts/{used} at TOOL_REV {dr.TOOL_REV[:12]} "
          f"from {dr.THEORG_CLONE}")
    print("token: asyla's hub token (the working directory's hub), "
          + ("held in this process, given only to kv_read" if metrics else "as the tool's BAO_ROOT_TOKEN"))


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("mode", nargs="?", choices=("provision", "verify"), default="provision",
                   help="provision (the default): create missing records; verify: check one of "
                        "d06's gateways (loki by default) with its check account(s)")
    p.add_argument("--registry", choices=(*REGISTRIES, "all"), default=None,
                   help="the gateway whose accounts to provision (default all, in the order "
                        f"{', '.join(REGISTRIES)}); verify takes one: loki (default), "
                        "pushgateway or prometheus-write")
    p.add_argument("--dry-run", action="store_true", help="print the plan; no fetch, no vault, no curl")
    args = p.parse_args(argv)
    mode = args.mode
    timeout = VERIFY_TIMEOUT if mode == "verify" else TOOL_TIMEOUT
    try:
        regs = chosen(args.registry, mode)
        names = {r: accounts(REGISTRIES[r][0]) for r in regs}
        for r in regs:
            show_plan(names[r], mode, r)
        metrics = mode == "verify" and regs[0] in METRICS
        show_tool(metrics)
        if args.dry_run:
            print("DRY RUN: nothing fetched, nothing written" + (", no curl" if mode == "verify" else ""))
            return 0
        tool_dir = Path(tempfile.mkdtemp(prefix="loki-accounts-"))   # 0700
        try:
            unpack(tool_dir)
            token = dr.hub_sign_in()
            if metrics:
                reg = regs[0]
                try:
                    bao = load_openbao(tool_dir)
                except Exception as e:   # the reviewed openbao.py at TOOL_REV; any failure stops
                    raise dr.Stop(f"cannot load openbao.py: {type(e).__name__}; nothing checked") from None
                if not verify_metrics(reg, read_password(bao, token, reg)):
                    print(f"stopped: {reg} gateway: a check failed at {METRICS[reg][0]} (its FAIL line is above)")
                    return 1
                print(f"{reg} gateway: every check passed at {METRICS[reg][0]}")
                return 0
            for r in regs:
                path, prefix = REGISTRIES[r]
                try:
                    proc = subprocess.run(tool_argv(tool_dir, path, mode), env=child_env(os.environ, token, prefix),
                                          capture_output=True, text=True, timeout=timeout)
                except subprocess.TimeoutExpired:
                    raise dr.Stop(f"loki_clients.py {mode} --registry {path.name}: no end in {timeout} s") from None
                except OSError as e:
                    raise dr.Stop(f"cannot run loki_clients.py: {type(e).__name__}; nothing written") from None
                out = dr.redact(proc.stdout + proc.stderr, [token]).rstrip()
                if out:
                    print(out)
                if proc.returncode != 0:
                    rest = regs[regs.index(r) + 1:]
                    print(f"stopped: loki_clients.py {mode} --registry {path.name} exit {proc.returncode} "
                          f"(its lines are above)" + (f"; not run: {', '.join(rest)}" if rest else ""))
                    return 1
                if mode == "verify":
                    print(f"loki gateway: every check passed at {GATEWAY_URL}")
                else:
                    print(f"{r} accounts: {len(names[r])} stored under {prefix}")
        finally:
            shutil.rmtree(tool_dir, ignore_errors=True)
        return 0
    except dr.Stop as e:
        print(f"stopped: {e}")
        return 1
    except subprocess.CalledProcessError as e:   # git show (names only in its command)
        print(f"stopped: {' '.join(e.cmd)}: exit {e.returncode}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
