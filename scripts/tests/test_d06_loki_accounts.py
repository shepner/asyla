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
import re
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
    out = [check("accounts: loki-clients.toml lists the 13 accounts, alert-relay and both check accounts among them",
                 len(la.accounts()) == 13 and "alert-relay" in la.accounts()
                 and all(n in la.accounts() for n in la.CHECK_ACCOUNTS), repr(la.accounts()))]
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


# Each registry, the observability.sh variable that lists its accounts, and the scopes its
# gateway's mode admits (theOrg DEPLOY.md, "Route modes": remote-write and pushgateway push only).
ACCOUNTS_VARS = {"loki": ("LOKI_GATEWAY_ACCOUNTS", (["push"], ["query"])),
                 "prometheus-write": ("PROMETHEUS_WRITE_GATEWAY_ACCOUNTS", (["push"],)),
                 "pushgateway": ("PUSHGATEWAY_GATEWAY_ACCOUNTS", (["push"],))}


def gateway_accounts_cases() -> list[bool]:
    """Each observability.sh <GATEWAY>_ACCOUNTS is what its registry yields: name:scope per
    account, comma-joined, in name order (theOrg loki_clients.py gateway-accounts)."""
    import tomllib
    sh = (dr.HERE / "observability.sh").read_text()
    exported = {w for m in re.finditer(r"^export (?:[^\n]*\\\n)*[^\n]*", sh, re.M) for w in m.group(0).split()}
    out = [check("registries: loki, prometheus-write and pushgateway, each its own file and prefix",
                 list(la.REGISTRIES) == ["loki", "prometheus-write", "pushgateway"]
                 and len({p for p, _ in la.REGISTRIES.values()}) == 3
                 and len({k for _, k in la.REGISTRIES.values()}) == 3
                 and all(k == f"secret/hubs/asyla/own/{p.stem}" for p, k in la.REGISTRIES.values()),
                 repr(la.REGISTRIES))]
    for reg, (var, scopes) in ACCOUNTS_VARS.items():
        clients = tomllib.loads(la.REGISTRIES[reg][0].read_text())["clients"]
        want = ",".join(f"{n}:{clients[n]['scope'][0]}" for n in sorted(clients))
        lines = [ln for ln in sh.splitlines() if ln.startswith(f"{var}=")]
        got = lines[0].split("=", 1)[1].strip('"') if len(lines) == 1 else ""
        out += [
            check(f"gateway {reg}: every account has exactly one scope its mode admits ({scopes})",
                  all(c.get("scope") in scopes for c in clients.values()), repr(clients)),
            check(f"gateway {reg}: observability.sh {var} = {la.REGISTRIES[reg][0].name}'s name:scope, in name order",
                  got == want, f"{got!r} != {want!r}"),
            check(f"gateway {reg}: observability.sh exports {var}", var in exported),
        ]
    return out


def argv_cases() -> list[bool]:
    tool_dir = Path("/stand-in/tool")
    argv = la.tool_argv(tool_dir)
    verify = la.tool_argv(tool_dir, mode="verify")
    return [check("argv: python -I loki_clients.py provision --registry <loki-clients.toml>",
                  argv == [sys.executable, "-I", "/stand-in/tool/loki_clients.py", "provision",
                           "--registry", str(dr.HERE / "loki-clients.toml")], repr(argv)),
            check("argv: verify --url https://loki.asyla.org --ca-volume '' (no --cacert)",
                  verify == [sys.executable, "-I", "/stand-in/tool/loki_clients.py", "verify",
                             "--registry", str(dr.HERE / "loki-clients.toml"),
                             "--url", "https://loki.asyla.org", "--ca-volume", ""], repr(verify))]


def main_cases() -> list[bool]:
    out = []
    rc, text = quiet(lambda: la.main(["--dry-run"]))
    out.append(check("dry run: exit 0, every registry's plan (default all), nothing fetched or signed in "
                     "(any contact fails)",
                     rc == 0 and "secret/hubs/asyla/own/loki-clients/alert-relay" in text
                     and "secret/hubs/asyla/own/prometheus-write-clients/host-agent-ws02" in text
                     and "secret/hubs/asyla/own/pushgateway-clients/staff-stack" in text
                     and "DRY RUN" in text, text))
    rc, text = quiet(lambda: la.main(["--registry", "pushgateway", "--dry-run"]))
    out.append(check("dry run --registry pushgateway: that registry's plan alone",
                     rc == 0 and "secret/hubs/asyla/own/pushgateway-clients/deploy-all" in text
                     and "loki-clients/" not in text and "prometheus-write-clients/" not in text, text))
    for reg in ("pushgateway", "prometheus-write", "all"):
        rc, text = quiet(lambda: la.main(["verify", "--registry", reg, "--dry-run"]))
        out.append(check(f"verify --registry {reg}: stops, exit 1 (verify is loki only; any contact fails)",
                         rc == 1 and "verify is loki only" in text, text))
    rc, text = quiet(lambda: la.main(["verify", "--dry-run"]))
    out.append(check("verify dry run: exit 0, the plan (url, no --cacert, both check accounts, curl), "
                     "nothing fetched, signed in or curled (any contact fails)",
                     rc == 0 and "DRY RUN" in text and "https://loki.asyla.org" in text
                     and "--ca-volume ''" in text and "curlimages/curl" in text
                     and all(n in text for n in la.CHECK_ACCOUNTS), text))

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
        signs = []
        dr.hub_sign_in = lambda: signs.append(1) or HUB_STAND_IN
        rc, text = quiet(la.main)
        argv, env, files = runs[0] if runs else ([], {}, [])
        want = [(la.tool_argv(Path(argv[2]).parent, p)[1:], k) for p, k in la.REGISTRIES.values()] if runs else []
        out += [
            check("run: the tool runs once per registry, in order, each with its own toml and prefix, "
                  "after one sign-in",
                  [(a[1:], e.get("LOKI_CLIENTS_KV_PREFIX")) for a, e, _ in runs] == want and len(signs) == 1,
                  repr(runs)),
            check("run: loki_clients.py and openbao.py unpacked beside it",
                  files == ["loki_clients.py", "openbao.py"], repr(files)),
            check("run: the code is unpacked once for every registry",
                  sum(1 for c in git_calls if c[0] == "show") == 2, repr(git_calls)),
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
        subprocess.run = stand_in_run
        rc, text = quiet(lambda: la.main(["verify"]))
        argv, env, files = runs[0] if runs else ([], {}, [])
        out.append(check("verify: the tool runs once as verify, with the same prefix and the hub token, "
                         "and exit 0 says every check passed",
                         rc == 0 and len(runs) == 1 and argv[1:] == la.tool_argv(Path(argv[2]).parent, mode="verify")[1:]
                         and env.get("BAO_ROOT_TOKEN") == HUB_STAND_IN
                         and env.get("LOKI_CLIENTS_KV_PREFIX") == la.KV_PREFIX
                         and "every check passed" in text and HUB_STAND_IN not in text, text))

        runs.clear()
        subprocess.run = lambda argv, env=None, **kw: Done(1, "", "::error::stand-in refused\n")
        rc, text = quiet(la.main)
        out.append(check("run: a tool failure exits 1 with its line and a stopped: line naming the "
                         "registries not run",
                         rc == 1 and "::error::stand-in refused" in text and "stopped:" in text
                         and "not run: prometheus-write, pushgateway" in text, text))

        runs.clear()
        subprocess.run = stand_in_run
        rc, text = quiet(lambda: la.main(["--registry", "prometheus-write"]))
        argv, env, files = runs[0] if runs else ([], {}, [])
        out.append(check("run --registry prometheus-write: the tool runs once, with that toml and prefix",
                         rc == 0 and len(runs) == 1
                         and argv[-1] == str(dr.HERE / "prometheus-write-clients.toml")
                         and env.get("LOKI_CLIENTS_KV_PREFIX") == "secret/hubs/asyla/own/prometheus-write-clients"
                         and "prometheus-write accounts: 1 stored" in text, text))

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


results = [*registry_cases(), *env_cases(), *path_cases(), *gateway_accounts_cases(), *argv_cases(),
           *main_cases()]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
