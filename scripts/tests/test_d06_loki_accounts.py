#!/usr/bin/env python3
"""Offline test of d06/apps/observability/loki_accounts.py: the accounts it reads, the tool's
environment and command line, the record path against compose.yml and deploy_role.py, and what
main() runs. No vault, no git, no network: subprocess.run, deploy_role.git and
deploy_role.hub_sign_in are replaced so that any contact fails the test, or answer from stand-ins.

    python3 scripts/tests/test_d06_loki_accounts.py

Exit 0 when every case passes.
"""
from __future__ import annotations

import contextlib
import io
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "d06/apps/observability"))
import deploy_role as dr  # noqa: E402
import loki_accounts as la  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the test reached out: {a[:1]}")


subprocess.run = _no_contact
dr.git = _no_contact
dr.hub_sign_in = _no_contact

HUB_STAND_IN = "stand-in-hub"
OTHER_STAND_IN = "stand-in-other"
DROPPED = ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_TOKEN", "BAO_ROOT_TOKEN", "OPENBAO_TOKEN_FILE",
           "OBSERVABILITY_DEPLOY_VAULT_TOKEN", "LOKI_CLIENTS_REGISTRY", "LOKI_CLIENTS_KV_PREFIX",
           "LOKI_CLIENTS_ANY")


def check(name: str, good: bool, detail: str = "") -> bool:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    return good


class Done:
    def __init__(self, rc: int, out: str = "", err: str = ""):
        self.returncode, self.stdout, self.stderr = rc, out, err


def quiet(call):
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc = call()
    return rc, buf.getvalue()


def registry_cases() -> list[bool]:
    out = [check("accounts: loki-clients.toml lists alert-relay", la.accounts() == ["alert-relay"])]
    with tempfile.TemporaryDirectory() as d:
        empty = Path(d) / "empty.toml"
        empty.write_text("# none\n")
        bad = Path(d) / "bad.toml"
        bad.write_text("[clients\n")
        for name, path, needle in (("a registry with no clients stops", empty, "no clients"),
                                   ("a registry that is not TOML stops", bad, "TOMLDecodeError"),
                                   ("a missing registry stops", Path(d) / "none.toml", "FileNotFoundError")):
            try:
                la.accounts(path)
                out.append(check(f"accounts: {name}", False, "no Stop"))
            except dr.Stop as e:
                out.append(check(f"accounts: {name}", needle in str(e), str(e)))
    return out


def env_cases() -> list[bool]:
    base = {"PATH": "/usr/bin", "HOME": "/home/x", "OPENBAO_ADDR": "https://vault.example",
            **{k: OTHER_STAND_IN for k in DROPPED}}
    env = la.child_env(base, HUB_STAND_IN)
    return [
        check("env: no other vault token and no LOKI_CLIENTS_* setting of the caller's reaches the tool",
              all(k not in env for k in DROPPED if k not in ("BAO_ROOT_TOKEN", "LOKI_CLIENTS_KV_PREFIX"))
              and OTHER_STAND_IN not in env.values(), repr(sorted(env))),
        check("env: the hub token as BAO_ROOT_TOKEN, asyla's prefix as LOKI_CLIENTS_KV_PREFIX",
              env.get("BAO_ROOT_TOKEN") == HUB_STAND_IN
              and env.get("LOKI_CLIENTS_KV_PREFIX") == "secret/hubs/asyla/own/loki-clients"),
        check("env: the rest of the caller's environment is kept (OPENBAO_ADDR, PATH, HOME)",
              all(env.get(k) == base[k] for k in ("OPENBAO_ADDR", "PATH", "HOME"))),
        check("env: the caller's environment is not changed", base["BAO_ROOT_TOKEN"] == OTHER_STAND_IN),
    ]


def path_cases() -> list[bool]:
    compose = (dr.HERE / "compose.yml").read_text()
    kv = [ln.split(":", 1)[1].strip().strip('"') for ln in compose.splitlines()
          if ln.strip().startswith("ALERT_RELAY_LOKI_KV:")]
    record = "own/loki-clients/alert-relay"
    return [
        check("path: the record is KV_PREFIX/alert-relay = compose.yml ALERT_RELAY_LOKI_KV less #password",
              len(kv) == 1 and kv[0].endswith("#password")
              and f"{la.KV_PREFIX}/alert-relay" == kv[0].removesuffix("#password"), repr(kv)),
        check("path: ... = deploy_role.kv_path of alert-relay's IDENTITIES record",
              f"{la.KV_PREFIX}/alert-relay" == dr.kv_path(record)
              and record in {c: rs for c, _, rs in dr.IDENTITIES}["alert-relay"]),
    ]


def argv_cases() -> list[bool]:
    tool_dir = Path("/stand-in/tool")
    argv = la.tool_argv(tool_dir)
    return [check("argv: python -I loki_clients.py provision --registry <loki-clients.toml>",
                  argv == [sys.executable, "-I", "/stand-in/tool/loki_clients.py", "provision",
                           "--registry", str(dr.HERE / "loki-clients.toml")], repr(argv))]


def main_cases() -> list[bool]:
    out = []
    rc, text = quiet(lambda: la.main(["--dry-run"]))
    out.append(check("dry run: exit 0, the plan, nothing fetched or signed in (any contact fails)",
                     rc == 0 and "secret/hubs/asyla/own/loki-clients/alert-relay" in text
                     and "DRY RUN" in text, text))

    saved = (dr.git, dr.hub_sign_in, subprocess.run)
    git_calls, runs = [], []

    def stand_in_git(*args, check=True):
        git_calls.append(args)
        return Done(0, "# stand-in code\n")

    def stand_in_run(argv, env=None, **kw):
        runs.append((argv, env, sorted(p.name for p in Path(argv[2]).parent.iterdir())))
        return Done(0, f"alert-relay: created {HUB_STAND_IN}\n")

    try:
        dr.git, dr.hub_sign_in, subprocess.run = stand_in_git, lambda: HUB_STAND_IN, stand_in_run
        rc, text = quiet(la.main)
        argv, env, files = runs[0] if runs else ([], {}, [])
        out += [
            check("run: the tool runs once, with loki_clients.py and openbao.py unpacked beside it",
                  len(runs) == 1 and argv[1:] == la.tool_argv(Path(argv[2]).parent)[1:]
                  and files == ["loki_clients.py", "openbao.py"], repr(runs)),
            check("run: the code is shown from TOOL_REV after a fetch, and TOOL_REV is checked on origin/main",
                  ("fetch", "--quiet", "origin") in git_calls
                  and ("merge-base", "--is-ancestor", dr.TOOL_REV, dr.MAIN) in git_calls
                  and ("show", f"{dr.TOOL_REV}:scripts/loki_clients.py") in git_calls, repr(git_calls)),
            check("run: the hub token is in the tool's environment only, as BAO_ROOT_TOKEN",
                  env.get("BAO_ROOT_TOKEN") == HUB_STAND_IN and HUB_STAND_IN not in " ".join(argv)),
            check("run: exit 0, the tool's line passed on with the token masked",
                  rc == 0 and "alert-relay: created" in text and HUB_STAND_IN not in text, text),
            check("run: the temp dir is gone after", bool(argv) and not Path(argv[2]).parent.exists()),
        ]

        runs.clear()
        subprocess.run = lambda argv, env=None, **kw: Done(1, "", "::error::stand-in refused\n")
        rc, text = quiet(la.main)
        out.append(check("run: a tool failure exits 1 with its line and a stopped: line",
                         rc == 1 and "::error::stand-in refused" in text and "stopped:" in text, text))

        signed = []
        dr.hub_sign_in = lambda: signed.append(1) or HUB_STAND_IN
        subprocess.run = _no_contact
        dr.git = lambda *a, check=True: Done(1 if a[0] == "merge-base" else 0, "")
        rc, text = quiet(la.main)
        out.append(check("run: TOOL_REV not on origin/main stops before the sign-in and the tool",
                         rc == 1 and "not on origin/main" in text and not signed, text))
    finally:
        dr.git, dr.hub_sign_in, subprocess.run = saved
    return out


results = [*registry_cases(), *env_cases(), *path_cases(), *argv_cases(), *main_cases()]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
