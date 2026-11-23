#!/usr/bin/env python3
"""Offline test of d06/apps/observability/deploy_role.py: the plan it builds, and what each step
sends where. No SSH, no vault, no git, no registry: subprocess.run, build_host.ssh and http_get
are replaced so that any contact fails the test (run_start's own cases run a local python child,
and alert_test_cases a local bash child with docker and the relay stubbed, nothing else; the
registry cases answer from a stand-in registry in this file).

    python3 scripts/tests/test_d06_deploy_role.py

Exit 0 when every case passes.
"""
from __future__ import annotations

import base64
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "d06/apps/observability"))
import deploy_role as dr  # noqa: E402

bh = dr.build_host


def _no_contact(*a, **kw):
    raise AssertionError(f"the test reached out: {a[:1]}")


REAL_HTTP_GET = dr.http_get
REAL_RUN = subprocess.run   # alert_test_cases only: a local bash child with every contact stubbed
subprocess.run = _no_contact
bh.ssh = _no_contact
dr.http_get = _no_contact

TAG = "f7579118fdac5d90101a5ec6698200ae2c9d836f"
REV = "a" * 40   # a stand-in revision
OBS_TOKENS = ["SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN", "EMPORIA_OPENBAO_WRAPPED_TOKEN", "ALERT_RELAY_OPENBAO_WRAPPED_TOKEN",
              "LOKI_GATEWAY_OPENBAO_WRAPPED_TOKEN", "PROMETHEUS_WRITE_GATEWAY_OPENBAO_WRAPPED_TOKEN",
              "PUSHGATEWAY_GATEWAY_OPENBAO_WRAPPED_TOKEN"]
PULL = "stand-in-pull"
HUB_STAND_IN = "stand-in-hub"
OTHER_STAND_IN = "stand-in-other"
OTHER_VAULT_VARS = ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_ROOT_TOKEN")


def check(name: str, good: bool, detail: str = "") -> bool:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    return good


def stops(name: str, needle: str, call) -> bool:
    try:
        call()
    except dr.Stop as e:
        return check(name, needle in str(e), str(e))
    return check(name, False, "no Stop")


class Done:
    def __init__(self, rc: int, out: str = "", err: str = ""):
        self.returncode, self.stdout, self.stderr = rc, out, err


SPEC = {"host": "d06", "apps_tree": "d06",
        "app": [{"name": "observability", "pull_token_env": "THEORG_REGISTRY_PULL_TOKEN", "verify": ["verify"],
                 "start_env_optional": list(OBS_TOKENS)}]}
SCRIPT = "~/scripts/d06/apps/observability/observability.sh"


def quiet(call):
    with contextlib.redirect_stdout(io.StringIO()) as buf, contextlib.redirect_stderr(io.StringIO()) as err:
        rc = call()
    return rc, buf.getvalue() + err.getvalue()


def with_pull_env(call):
    saved = os.environ.get("THEORG_REGISTRY_PULL_TOKEN")
    os.environ["THEORG_REGISTRY_PULL_TOKEN"] = PULL
    try:
        return call()
    finally:
        if saved is None:
            os.environ.pop("THEORG_REGISTRY_PULL_TOKEN", None)
        else:
            os.environ["THEORG_REGISTRY_PULL_TOKEN"] = saved


def d06_spec_case() -> bool:
    try:
        dr.check_spec(bh.load_spec("d06"), dr.IDENTITIES)
    except dr.Stop as e:
        return check("spec: d06/host.toml sends every identity's variable", False, str(e))
    return check("spec: d06/host.toml sends every identity's variable", True)


def pull_cases() -> list[bool]:
    out, calls = [], []

    def fake(rc, stdout, stderr=""):
        def f(target, cmd, **kw):
            calls.append((target, cmd, kw.get("stdin")))
            return Done(rc, stdout, stderr)
        return f

    good = f"{REG}/theorg/observability-alert-relay:{TAG}\nprom/prometheus:v3\n"
    bh.ssh = fake(0, good)
    rc, printed = quiet(lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG, REG)))
    out.append(check("images: the pull token goes over stdin only, by name in the command",
                     len(calls) == 1 and calls[0][2] == PULL + "\n" and PULL not in calls[0][1]
                     and "OBSERVABILITY_REGISTRY_PULL_TOKEN" in calls[0][1] and "observability.sh images" in calls[0][1]
                     and PULL not in printed, repr(calls)))
    got = quiet(lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG, REG)))[0]
    out.append(check("images: returns the theOrg images it pulled (the list `digests` must match)",
                     got == [f"{REG}/theorg/observability-alert-relay:{TAG}"], repr(got)))
    for name, listed in (("on another registry host", f"other.example/theorg/observability-alert-relay:{TAG}\n"),
                         ("on the registry host with another port", f"{REG}:8443/theorg/observability-alert-relay:{TAG}\n"),
                         ("with no host (Docker Hub's theorg)", f"theorg/observability-alert-relay:{TAG}\n")):
        bh.ssh = fake(0, good + listed)
        out.append(stops(f"images: a theOrg image {name} stops, nothing minted", f"not on {REG}",
                         lambda: with_pull_env(lambda: quiet(lambda: dr.pull_images(SPEC, TAG, REG)))))
    bh.ssh = fake(0, f"{REG}/theorg/observability-alert-relay:2144f83c\n")
    out.append(stops("images: a theOrg image of another tag stops before any mint", "not of",
                     lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG, REG))))
    out.append(stops("images: a stale scripts tree names the fix (merge, then install master with --only bootstrap)",
                     "build_host.py d06 build --only bootstrap --apply",
                     lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG, REG))))
    bh.ssh = fake(0, "prom/prometheus:v3\n")
    out.append(stops("images: no theOrg image at all stops", "0 theOrg image(s)",
                     lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG, REG))))
    bh.ssh = fake(1, "", f"login failed for {PULL}\n")
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        got = stops("images: a failed pull stops, nothing minted", "nothing minted",
                    lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG, REG)))
    out.append(got)
    out.append(check("images: a failed pull's output is shown with the token redacted",
                     PULL not in buf.getvalue() and "login failed for ..." in buf.getvalue(), buf.getvalue()))
    # The value straddles the 2000-character cut: cut first, then redact, would leave its end.
    bh.ssh = fake(1, "", "a" * 100 + PULL + "b" * 1995)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stderr(buf):
            with_pull_env(lambda: dr.pull_images(SPEC, TAG, REG))
    except dr.Stop:
        pass
    out.append(check("images: a failed pull's output is redacted before it is cut (no part of the token)",
                     PULL[-5:] not in buf.getvalue() and len(buf.getvalue().strip()) == 2000, repr(buf.getvalue()[:40])))

    def timeout(target, cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, kw.get("timeout"))
    bh.ssh = timeout
    out.append(stops("images: no answer in time is one clear line, nothing minted", "nothing minted",
                     lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG, REG))))
    bh.ssh = _no_contact
    return out


def verify_cases() -> list[bool]:
    out, calls = [], []

    def fake(rc):
        def f(target, cmd, **kw):
            calls.append((target, cmd, kw))
            return Done(rc)
        return f

    bh.ssh = fake(0)
    dr.verify_app(SPEC)
    out.append(check("verify: the app's own verify on d06, streamed, no token on stdin",
                     calls == [("d06", f"{SCRIPT} verify", {"check": False, "stream": True,
                                                            "timeout": dr.VERIFY_TIMEOUT})], repr(calls)))
    calls.clear()
    dr.verify_app(SPEC, REV)
    out.append(check("verify: with the revision, OBSERVABILITY_REVISION=<sha> leads the command (not a secret)",
                     [c[1] for c in calls] == [f"OBSERVABILITY_REVISION={REV} {SCRIPT} verify"], repr(calls)))
    calls.clear()
    out.append(stops("verify: a revision that is not 40 hex stops, nothing run", "not a 40-hex sha",
                     lambda: dr.verify_app(SPEC, "a; reboot")))
    out.append(check("verify: nothing ran for the bad revision", calls == [], repr(calls)))
    bh.ssh = fake(1)
    out.append(stops("verify: a failed verify stops", "does not verify", lambda: dr.verify_app(SPEC)))

    def timeout(target, cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, kw.get("timeout"))
    bh.ssh = timeout
    out.append(stops("verify: no answer in time is one clear line", "no end in", lambda: dr.verify_app(SPEC)))
    bh.ssh = _no_contact
    out.append(stops("spec: an app without verify stops before anything runs", "has no verify",
                     lambda: dr.check_spec({**SPEC, "app": [{k: v for k, v in SPEC["app"][0].items() if k != "verify"}]},
                                           dr.IDENTITIES)))
    return out


def run_start_cases() -> list[bool]:
    """run_start with a local child (no contact): lines pass through; an ::error:: line means the
    start never ran."""
    out = []
    code = "import sys; print('minted'); print(sys.argv[1]); sys.exit(int(sys.argv[2]))"
    for said, rc, started, name in (
            ("::error::scrape-proxy: no vault identity minted", 1, False, "an ::error:: line: the mint failed"),
            ("[ERROR] up failed", 1, True, "a failure without ::error::: the start ran"),
            ("done", 0, True, "a clean run")):
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            got = dr.run_start([sys.executable, "-c", code, said, str(rc)], dict(os.environ))
        out.append(check(f"run_start: {name}", got == (rc, started) and f"minted\n{said}\n" == buf.getvalue(),
                         repr((got, buf.getvalue()))))
    return out


GIVEN_STAND_IN = "stand-in-given"   # OBSERVABILITY_DEPLOY_VAULT_TOKEN's stand-in


def given_token_cases() -> list[bool]:
    """OBSERVABILITY_DEPLOY_VAULT_TOKEN and the two path variables, outside main: unset, the
    workstation's; set, taken out of the environment; malformed, a Stop."""
    out, name = [], dr.VAULT_TOKEN_ENV
    saved = os.environ.pop(name, None)
    try:
        out.append(check("given token: the variable names are the documented ones",
                         (dr.VAULT_TOKEN_ENV, dr.THEORG_CLONE_ENV, dr.SECRETS_CLIENT_ENV)
                         == ("OBSERVABILITY_DEPLOY_VAULT_TOKEN", "OBSERVABILITY_DEPLOY_THEORG_CLONE",
                             "OBSERVABILITY_DEPLOY_SECRETS_CLIENT")
                         and all(n in dr.__doc__ for n in (dr.VAULT_TOKEN_ENV, dr.THEORG_CLONE_ENV, dr.SECRETS_CLIENT_ENV))))
        out.append(check("given token: unset is None (the hub sign-in)", dr.take_given_token() is None))
        os.environ[name] = f" {GIVEN_STAND_IN}\n"
        got = dr.take_given_token()
        out.append(check("given token: set is its value, stripped, and no longer in the environment",
                         got == GIVEN_STAND_IN and name not in os.environ, repr(got)))
        for what, raw, needle in (("set but empty", "", "is set but empty"), ("blanks only", " \n", "is set but empty"),
                                  ("two words", "stand-in one", "is not one token"),
                                  ("a control character", "stand-in\x07x", "is not one token")):
            os.environ[name] = raw
            out.append(stops(f"given token: {what} stops", needle, dr.take_given_token))
            out.append(check(f"given token: {what}: taken out of the environment all the same", name not in os.environ))
        env = dr.child_env({name: OTHER_STAND_IN, "PATH": "/bin"}, GIVEN_STAND_IN, SPEC)
        out.append(check("given token: the minting tool's env has it as BAO_TOKEN only, never under its own name",
                         env == {"PATH": "/bin", "BAO_TOKEN": GIVEN_STAND_IN}, repr(sorted(env))))
    finally:
        os.environ.pop(name, None)
        if saved is not None:
            os.environ[name] = saved
    home = Path.home()
    out.append(check("paths: unset, the workstation's clones under ~/local/theOrg",
                     dr.env_path("OBSERVABILITY_TEST_UNSET_PATH", home / "x") == home / "x"
                     and (os.environ.get(dr.THEORG_CLONE_ENV) or dr.THEORG_CLONE == home / "local/theOrg/projects/observability")
                     and (os.environ.get(dr.SECRETS_CLIENT_ENV)
                          or dr.SECRETS_CLIENT == home / "local/theOrg/projects/secrets-vault/client")))
    import importlib.util
    saved = {n: os.environ.get(n) for n in (dr.THEORG_CLONE_ENV, dr.SECRETS_CLIENT_ENV)}
    os.environ.update({dr.THEORG_CLONE_ENV: "/builds/theorg/observability", dr.SECRETS_CLIENT_ENV: ""})
    try:
        spec = importlib.util.spec_from_file_location("deploy_role_paths", REPO / "d06/apps/observability/deploy_role.py")
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
    finally:
        for n, v in saved.items():
            os.environ.pop(n, None)
            if v is not None:
                os.environ[n] = v
    calls = []
    real_run = subprocess.run
    subprocess.run = lambda argv, **kw: calls.append(argv) or Done(0)
    try:
        m.git("cat-file", "-e", "x", check=False)
    finally:
        subprocess.run = real_run
    out.append(check("paths: OBSERVABILITY_DEPLOY_THEORG_CLONE names the clone every git call runs in; "
                     "an empty OBSERVABILITY_DEPLOY_SECRETS_CLIENT is the default",
                     m.THEORG_CLONE == Path("/builds/theorg/observability")
                     and m.SECRETS_CLIENT == home / "local/theOrg/projects/secrets-vault/client"
                     and calls == [["git", "-C", "/builds/theorg/observability", "cat-file", "-e", "x"]]
                     and m.TOOL_REV == dr.TOOL_REV, repr((m.THEORG_CLONE, m.SECRETS_CLIENT, calls))))
    return out


def given_token_main_cases(seen: dict) -> list[bool]:
    """main with OBSERVABILITY_DEPLOY_VAULT_TOKEN, under main_cases' stand-ins: the given token is
    BAO_TOKEN instead of the hub sign-in, out of the environment before the first step; every step
    and check as without it."""
    out, name = [], dr.VAULT_TOKEN_ENV
    real_pull = dr.pull_images

    def pull(spec, tag, registry):
        seen["in env at the pull"] = name in os.environ
        seen.setdefault("order", []).append(f"images {registry}")
    dr.pull_images = pull
    try:
        seen.clear()
        os.environ[name] = GIVEN_STAND_IN
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main(["--dry-run"])))
        out.append(check("given token: dry run names it as set, never its value, and runs nothing",
                         rc == 0 and not seen and f"4. the vault token {name} gave (set) as BAO_TOKEN" in printed
                         and "hub token" not in printed and "stand-in" not in printed, printed))
        seen.clear()
        os.environ[name] = GIVEN_STAND_IN
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        env, argv = seen.get("env", {}), seen.get("argv", [])
        out.append(check("given token: BAO_TOKEN is the given token, no hub sign-in, no other vault token",
                         rc == 0 and env.get("BAO_TOKEN") == GIVEN_STAND_IN and "hub" not in seen
                         and not any(n in env for n in (name, *OTHER_VAULT_VARS, *OBS_TOKENS)),
                         repr((rc, sorted(env), seen.get("hub")))))
        out.append(check("given token: out of the environment before the first step, and after",
                         seen.get("in env at the pull") is False and name not in os.environ, repr(seen)))
        out.append(check("given token: the same steps (images, revision, the tool at R), the same mint, the verify with R",
                         seen.get("order") == ["images gitea.asyla.org", "revision", f"tool {REV}"]
                         and argv[3:5] == ["--token-role", "observability-d06"]
                         and seen.get("verify") == ("d06", f"OBSERVABILITY_REVISION={REV} {SCRIPT} verify"),
                         repr((seen.get("order"), argv[3:5], seen.get("verify")))))
        out.append(check("given token: never printed, never in an argument", "stand-in" not in printed + " ".join(argv),
                         printed))
        seen.clear()
        seen.update(check_stop="theOrg's minting tool changed between TOOL_REV f7579118fdac and R aaaaaaaaaaaa")
        dr.unpack_tool = lambda rev, into: dr.check_tool(rev)
        os.environ[name] = GIVEN_STAND_IN
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("given token: a changed minting tool still stops before the mint, exit 1",
                         rc == 1 and "minting tool changed" in printed and "argv" not in seen and "hub" not in seen,
                         repr((rc, seen, printed))))
        seen.clear()
        seen.update(revision_stop="the theOrg images were built from different commits; nothing minted")
        os.environ[name] = GIVEN_STAND_IN
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("given token: an unread provenance still stops before the tool, exit 1",
                         rc == 1 and seen.get("order") == ["images gitea.asyla.org", "revision"] and "argv" not in seen,
                         repr((rc, seen))))
        seen.clear()
        os.environ[name] = ""
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("given token: set but empty stops before anything runs (no hub sign-in in its place)",
                         rc == 1 and not seen and f"{name} is set but empty" in printed, repr((rc, seen, printed))))
    finally:
        dr.pull_images = real_pull
        dr.unpack_tool = lambda rev, into: seen.setdefault("order", []).append(f"tool {rev}")
        os.environ.pop(name, None)
    return out


def main_cases() -> list[bool]:
    out = []
    seen = {}

    def fake_start(argv, env):
        seen["argv"], seen["env"] = argv, env
        if seen.get("raise"):
            raise seen["raise"]
        return seen.get("rc", 0), seen.get("started", True)

    def fake_verify(target, cmd, **kw):
        seen["verify"] = (target, cmd)
        return Done(seen.get("verify_rc", 0))

    def fake_revision(spec, tag, registry, pulled):
        seen.setdefault("order", []).append("revision")
        if seen.get("revision_stop"):
            raise dr.Stop(seen["revision_stop"])
        return REV

    def fake_check(rev):
        seen.setdefault("order", []).append(f"check {rev}")
        if seen.get("check_stop"):
            raise dr.Stop(seen["check_stop"])

    def fake_hub():
        seen["hub"] = True
        return HUB_STAND_IN

    real = (dr.unpack_tool, dr.pull_images, dr.hub_sign_in, dr.stack_tag, dr.has_tool, dr.build_host.load_spec,
            dr.run_start, dr.stack_revision, dr.check_tool)
    dr.unpack_tool = lambda rev, into: seen.setdefault("order", []).append(f"tool {rev}")
    dr.pull_images = lambda spec, tag, registry: seen.setdefault("order", []).append(f"images {registry}")
    dr.stack_revision = fake_revision
    dr.check_tool = fake_check
    dr.hub_sign_in = fake_hub
    dr.stack_tag = lambda script: "latest"
    dr.has_tool = lambda tag: True
    dr.build_host.load_spec = lambda host: SPEC
    dr.run_start = fake_start
    bh.ssh = fake_verify
    saved = {n: os.environ.get(n) for n in ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_ROOT_TOKEN", OBS_TOKENS[0],
                                            "THEORG_REGISTRY_PULL_TOKEN")}
    os.environ.update(dict.fromkeys((*OTHER_VAULT_VARS, OBS_TOKENS[0]), OTHER_STAND_IN))
    try:
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main(["--dry-run"])))
        out.append(check("dry run: prints the plan (images, revision, tool, mint, verify with R), runs nothing, exit 0",
                         rc == 0 and not seen and "DRY RUN" in printed and all(n in printed for n in OBS_TOKENS)
                         and f"2. d06: {SCRIPT} digests" in printed and f"R and TOOL_REV {dr.TOOL_REV[:12]} on its origin/main" in printed
                         and "git show TOOL_REV:scripts/" in printed and "source on gitea.asyla.org" in printed
                         and f"6. d06: OBSERVABILITY_REVISION=R {SCRIPT} verify" in printed
                         and "stand-in" not in printed, printed))
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        env, argv = seen.get("env", {}), seen.get("argv", [])
        out.append(check("run: BAO_TOKEN is the hub token in the minting tool's env only; no other vault token, no stale wrapped one",
                         rc == 0 and env.get("BAO_TOKEN") == HUB_STAND_IN and env.get("THEORG_REGISTRY_PULL_TOKEN") == PULL
                         and not any(n in env for n in ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_ROOT_TOKEN", *OBS_TOKENS))
                         and "BAO_TOKEN" not in os.environ and "stand-in" not in printed + " ".join(argv),
                         repr((rc, sorted(env), printed))))
        out.append(check("run: vault_identity.py --token-role observability-d06, one --identity per component, then the app start",
                         argv[1:2] == ["-I"] and argv[2].endswith("vault_identity.py")
                         and argv[3:5] == ["--token-role", "observability-d06"] and argv.count("--identity") == 6
                         and argv[argv.index("--") + 1:][1:] == [str(REPO / "scripts/build_host.py"), "d06", "build", "--only",
                                                                 "apps", "--app", "observability", "--apply"],
                         repr(argv)))
        out.append(check("run: images, then the revision, then the tool at that revision, then the mint",
                         seen.get("order") == ["images gitea.asyla.org", "revision", f"tool {REV}"], repr(seen.get("order"))))
        out.append(check("run: after a clean start, the app's verify runs on d06 with the revision; exit 0",
                         rc == 0 and seen.get("verify") == ("d06", f"OBSERVABILITY_REVISION={REV} {SCRIPT} verify")
                         and "verifies" in printed and REV in printed,
                         repr((rc, seen.get("verify"), printed))))
        seen.clear()
        seen.update(revision_stop="the theOrg images were built from different commits; nothing minted")
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("run: a revision that cannot be read stops after the pull: no tool, no mint, no start, exit 1",
                         rc == 1 and seen.get("order") == ["images gitea.asyla.org", "revision"] and "argv" not in seen
                         and "verify" not in seen and "different commits" in printed, repr((rc, seen, printed))))
        seen.clear()
        seen.update(verify_rc=1)
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("run: a verify that fails exits 1", rc == 1 and "does not verify" in printed, printed))
        seen.clear()
        seen.update(rc=1, started=False)
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("run: a mint failure says the mint failed, nothing started; no verify",
                         rc == 1 and "the mint failed" in printed and "nothing started" in printed
                         and "verify" not in seen, printed))
        seen.clear()
        seen.update(rc=1, started=True)
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("run: a start failure says the stack may be partly recreated, names status and verify; no verify run",
                         rc == 1 and "the start failed" in printed and "partly recreated" in printed
                         and f"`{SCRIPT} status`" in printed and f"`{SCRIPT} verify`" in printed
                         and "verify" not in seen, printed))
        seen.clear()
        seen.update(rc=0, started=True)
        seen["raise"] = FileNotFoundError(2, "No such file or directory")
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("run: a start that cannot run is one clear line, exit 1, no traceback",
                         rc == 1 and "cannot run vault_identity.py: FileNotFoundError" in printed
                         and "Traceback" not in printed, printed))
        seen.clear()
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main(["--revision-only"])))
        out.append(check("revision only: images, revision, the tool check; prints R; no hub token, no tool written, "
                         "no mint, no start, no verify; exit 0",
                         rc == 0 and seen.get("order") == ["images gitea.asyla.org", "revision", f"check {REV}"]
                         and "hub" not in seen and "argv" not in seen and "verify" not in seen
                         and f"R = {REV}" in printed and "nothing minted, nothing started" in printed
                         and "stand-in" not in printed, repr((rc, seen, printed))))
        seen.clear()
        seen.update(check_stop="theOrg's minting tool changed between TOOL_REV f7579118fdac and R aaaaaaaaaaaa")
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main(["--revision-only"])))
        out.append(check("revision only: a changed minting tool stops, exit 1, no R line",
                         rc == 1 and "minting tool changed" in printed and "R = " not in printed and "hub" not in seen,
                         repr((rc, printed))))
        seen.clear()
        seen.update(revision_stop="the theOrg images were built from different commits; nothing minted")
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main(["--revision-only"])))
        out.append(check("revision only: an unread revision stops before the tool check, exit 1",
                         rc == 1 and seen.get("order") == ["images gitea.asyla.org", "revision"], repr((rc, seen))))
        seen.clear()
        try:
            rc = quiet(lambda: with_pull_env(lambda: dr.main(["--dry-run", "--revision-only"])))[0]
        except SystemExit as e:   # argparse: the two modes exclude each other
            rc = e.code
        out.append(check("revision only: not with --dry-run", rc == 2 and not seen, repr(rc)))
        out += given_token_main_cases(seen)
        seen.clear()
        os.environ.pop("THEORG_REGISTRY_PULL_TOKEN", None)
        rc, printed = quiet(lambda: dr.main([]))
        out.append(check("run: no pull token stops before anything runs", rc == 1 and not seen
                         and "THEORG_REGISTRY_PULL_TOKEN is not in the environment" in printed, printed))
    finally:
        (dr.unpack_tool, dr.pull_images, dr.hub_sign_in, dr.stack_tag, dr.has_tool, dr.build_host.load_spec,
         dr.run_start, dr.stack_revision, dr.check_tool) = real
        bh.ssh = _no_contact
        for n, v in saved.items():
            os.environ.pop(n, None)
            if v is not None:
                os.environ[n] = v
    return out


def digests_cases() -> list[bool]:
    """image_digests: `observability.sh digests` on d06 (no token), theOrg lines only."""
    out, calls = [], []

    def fake(rc, stdout):
        def f(target, cmd, **kw):
            calls.append((target, cmd, kw.get("stdin")))
            return Done(rc, stdout)
        return f

    d1, d2 = "sha256:" + "1" * 64, "sha256:" + "2" * 64
    bh.ssh = fake(0, f"{REG}/theorg/observability-loki:latest {d1} {d2}\n"
                     f"{REG}/theorg/observability-vector:latest -\nprom/blackbox:v1 {d1}\n")
    got = dr.image_digests(SPEC, REG)
    out.append(check("digests: `observability.sh digests` on d06, no stdin (no token); theOrg images only, - is none",
                     calls == [("d06", f"{SCRIPT} digests", None)]
                     and got == {f"{REG}/theorg/observability-loki:latest": [d1, d2],
                                 f"{REG}/theorg/observability-vector:latest": []}, repr((calls, got))))
    bh.ssh = fake(1, "")
    out.append(stops("digests: a failed read stops, nothing minted", "exit 1", lambda: quiet(lambda: dr.image_digests(SPEC, REG))))
    bh.ssh = fake(0, f"prom/blackbox:v1 {d1}\n")
    out.append(stops("digests: no theOrg image stops", "listed no theOrg image", lambda: dr.image_digests(SPEC, REG)))
    for name, line in (("a digest that is not sha256:<64 hex>", f"{REG}/theorg/observability-loki:latest sha256:abc\n"),
                       ("an upper-case digest", f"{REG}/theorg/observability-loki:latest {d1.upper()}\n"),
                       ("a digest with - beside it", f"{REG}/theorg/observability-loki:latest {d1} -\n"),
                       ("a line with no digest field", f"{REG}/theorg/observability-loki:latest\n")):
        bh.ssh = fake(0, line)
        out.append(stops(f"digests: {name} stops", "is not sha256:<64 hex>", lambda: dr.image_digests(SPEC, REG)))
    bh.ssh = fake(0, f"{REG}/theorg/observability-loki:latest {d1}\nother.example/theorg/observability-vector:latest {d2}\n")
    out.append(stops("digests: a theOrg image on another registry host stops", f"not on {REG}",
                     lambda: dr.image_digests(SPEC, REG)))
    bh.ssh = _no_contact
    return out


def tool_cases() -> list[bool]:
    """check_tool and unpack_tool against a stand-in git: the tool runs from TOOL_REV, never R;
    a change between them stops before anything is written; every git call has no prompt and a
    timeout."""
    out = []

    def fake_git(diff_rc=0, on_main=True, timeout_on=""):
        calls = []

        def run(argv, **kw):
            calls.append((argv, kw))
            sub = argv[3:]   # git -C <clone> ...
            if sub[0] == timeout_on:
                raise subprocess.TimeoutExpired(argv, kw.get("timeout"))
            if sub[0] == "merge-base":
                return Done(0 if on_main or sub[2] == dr.TOOL_REV else 1)
            if sub[0] == "diff":
                return Done(diff_rc)
            if sub[0] == "show":
                return Done(0, f"# {sub[1]}\nparser.add_argument('--token-role')\n")
            return Done(0)   # fetch, cat-file
        return run, calls

    def unpack(**kw):
        run, calls = fake_git(**kw)
        subprocess.run = run
        d = tempfile.mkdtemp()
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                dr.unpack_tool(REV, Path(d))
            return calls, {p.name: p.read_text() for p in Path(d).iterdir()}
        finally:
            subprocess.run = _no_contact
            for p in Path(d).iterdir():
                p.unlink()
            os.rmdir(d)

    calls, files = unpack()
    subs = [c[0][3:] for c in calls]
    out.append(check("tool: TOOL_REV is 001a2ac, the commit asyla reviewed",
                     dr.TOOL_REV == "001a2ac8d124976ef929112a06644a942078564e"))
    out.append(check("tool: unchanged between TOOL_REV and R: the files are git show TOOL_REV:..., never R",
                     sorted(files) == ["openbao.py", "vault_identity.py"]
                     and all(v.startswith(f"# {dr.TOOL_REV}:scripts/") for v in files.values())
                     and not any(s[0] == "show" and REV in s[1] for s in subs), repr((subs, files))))
    out.append(check("tool: the diff is TOOL_REV against R over the two files only",
                     ["diff", "--quiet", dr.TOOL_REV, REV, "--", "scripts/vault_identity.py", "scripts/openbao.py"] in subs,
                     repr(subs)))
    out.append(check("tool: R and TOOL_REV checked against refs/remotes/origin/main",
                     ["merge-base", "--is-ancestor", REV, "refs/remotes/origin/main"] in subs
                     and ["merge-base", "--is-ancestor", dr.TOOL_REV, "refs/remotes/origin/main"] in subs, repr(subs)))
    out.append(check("tool: every git call has GIT_TERMINAL_PROMPT=0 and a 120 s timeout",
                     calls and all(kw.get("env", {}).get("GIT_TERMINAL_PROMPT") == "0" and kw.get("timeout") == 120
                                   for _, kw in calls), repr([kw.get("timeout") for _, kw in calls])))
    for name, needle, kw in (
            ("a minting tool changed between TOOL_REV and R stops", "minting tool changed between TOOL_REV", {"diff_rc": 1}),
            ("a failed diff stops", "exit 128", {"diff_rc": 128}),
            ("R not on origin/main stops", f"R {REV[:12]} is not on origin/main", {"on_main": False}),
            ("a git fetch with no end in time is one Stop line", "git fetch in", {"timeout_on": "fetch"}),
            ("a git diff with no end in time is one Stop line", "no end in 120 s", {"timeout_on": "diff"})):
        written = {}

        def go(kw=kw):
            c, f = unpack(**kw)
            written.update(f)
        out.append(stops(f"tool: {name}, nothing written, nothing minted", needle, go))
        out.append(check(f"tool: {name}: no file written", written == {}, repr(written)))
    run, calls = fake_git(diff_rc=1)
    subprocess.run = run
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            dr.check_tool(REV)
    except dr.Stop:
        pass
    finally:
        subprocess.run = _no_contact
    out.append(check("tool: a changed tool stops before any git show", not any(c[0][3] == "show" for c in calls),
                     repr([c[0][3] for c in calls])))
    return out


def redirect_cases() -> list[bool]:
    """A redirect never carries the Authorization header off the registry's host, nor off https."""
    import urllib.request
    h = dr.AuthStaysRedirect()

    def follow(to):
        req = urllib.request.Request("https://reg.example/v2/r/blobs/x", headers={"Authorization": "Bearer stand-in-bearer"})
        return h.redirect_request(req, None, 307, "Temporary Redirect", {}, to)

    away, same = follow("https://storage.example/blob?sig=1"), follow("https://reg.example/v2/r/blobs/y")
    port, port443 = follow("https://reg.example:8443/v2/r/blobs/y"), follow("https://reg.example:443/v2/r/blobs/y")

    class Body:
        def __init__(self, n):
            self.status, self.headers, self.buf, self.asked = 200, {}, io.BytesIO(b"x" * n), []

        def read(self, n=-1):
            self.asked.append(n)
            return self.buf.read(n)

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    class Opener:
        def __init__(self, n):
            self.body = Body(n)

        def open(self, req, timeout=None):
            return self.body

    def capped(n):
        saved, dr.OPENER = dr.OPENER, Opener(n)
        try:
            return REAL_HTTP_GET("https://reg.example/v2/r/blobs/x", {}), dr.OPENER.body.asked
        finally:
            dr.OPENER = saved
    (st, _, body), asked = capped(dr.MAX_BODY)
    return [
        check("redirect: to the same host on another port, without the Authorization header",
              port.get_header("Authorization") is None and not port.has_header("Authorization")),
        check("redirect: to the same host with :443 named (the default port), the header stays",
              port443.get_header("Authorization") == "Bearer stand-in-bearer"),
        check("http_get: a body of 4 MiB is read whole, asking for one byte more at most",
              st == 200 and len(body) == dr.MAX_BODY == 4 * 1024 * 1024 and asked == [dr.MAX_BODY + 1]),
        stops("http_get: a body over 4 MiB stops, nothing minted", "an answer over 4 MiB",
              lambda: capped(dr.MAX_BODY + 1)),
        check("redirect: to another host, without the Authorization header",
              away.full_url.startswith("https://storage.example/") and away.get_header("Authorization") is None
              and not away.has_header("Authorization")),
        check("redirect: on the same host over https, the header stays",
              same.get_header("Authorization") == "Bearer stand-in-bearer"),
        stops("redirect: off https is refused", "off https", lambda: follow("http://reg.example/v2/r/blobs/y")),
        stops("http_get: a URL that is not https is refused before any contact", "not https",
              lambda: REAL_HTTP_GET("http://reg.example/v2/", {})),
        check("http_get: the opener's redirect handler is AuthStaysRedirect, not urllib's own",
              [type(x) for x in dr.OPENER.handlers if isinstance(x, urllib.request.HTTPRedirectHandler)]
              == [dr.AuthStaysRedirect]),
    ]


REG = "gitea.example"   # the registry, and theOrg's forge (a provenance source's host)
BASIC = "Basic " + base64.b64encode(f"{dr.REGISTRY_USER}:{PULL}".encode()).decode()
BEARER = "stand-in-bearer"
SOURCE = f"https://{REG}/theOrg/observability"
NAMES = ("alert-relay", "alertmanager", "blackbox-exporter", "emporia-collector", "loki", "prometheus",
         "prometheus-trends", "pushgateway", "scrape-proxy", "vector")


def digest(*parts: str) -> str:
    import hashlib
    return "sha256:" + hashlib.sha256("/".join(parts).encode()).hexdigest()


def sha(body: bytes) -> str:
    import hashlib
    return "sha256:" + hashlib.sha256(body).hexdigest()


class StandInRegistry:
    """A content-addressed registry that answers http_get from what each image's provenance says:
    {name: [(source, revision), ...]} (one per attestation; [] for an index without one). MORE
    gives an image a second index digest the same way. Every manifest and blob is stored under the
    sha256 of its body, as a registry does; TAMPER names an image whose index answers with other
    bytes than its digest."""

    def __init__(self, prov: dict, realm: str = f"https://{REG}/v2/token", scheme: str = "Bearer",
                 token_status: int = 200, predicate: str = "v1", index_body: bytes | None = None,
                 more: dict | None = None, tamper: str = ""):
        self.prov, self.realm, self.scheme, self.token_status = prov, realm, scheme, token_status
        self.predicate, self.calls, self.store, self.index = predicate, [], {}, {}
        for n, atts in prov.items():
            self.index[n] = [self._put(index_body) if index_body is not None else self._image(n, atts, "1")]
            if more and n in more:
                self.index[n].append(self._image(n, more[n], "2"))
        if tamper:
            d = self.index[tamper][0]
            self.store[d] = self.store[d] + b" "

    def _put(self, body: bytes) -> str:
        self.store[sha(body)] = body
        return sha(body)

    def _image(self, n: str, atts: list, key: str) -> str:
        image = self._put(f"image manifest {n} {key}".encode())
        ms = [{"digest": image, "platform": {"os": "linux", "architecture": "amd64"}}]
        for src, rev in atts:
            vcs = {"source": src, "revision": rev}
            pred = ({"runDetails": {"metadata": {"buildkit_metadata": {"vcs": vcs}}}} if self.predicate == "v1"
                    else {"metadata": {"https://mobyproject.org/buildkit@v1#metadata": {"vcs": vcs}}})
            blob = self._put(json.dumps({"predicate": pred, "image": f"{n} {key}"}).encode())
            att = self._put(json.dumps({"layers": [{"digest": blob, "annotations": {
                "in-toto.io/predicate-type": "https://slsa.dev/provenance/v1"}}]}).encode())
            ms.append({"digest": att, "annotations": {"vnd.docker.reference.type": "attestation-manifest",
                                                      "vnd.docker.reference.digest": image}})
        return self._put(json.dumps({"manifests": ms}).encode())

    def pulled(self) -> list[str]:
        return [f"{REG}/theorg/observability-{n}:latest" for n in self.prov]

    def digests_out(self, missing: str = "") -> str:
        return "".join(f"{REG}/theorg/observability-{n}:latest {'-' if n == missing else ' '.join(self.index[n])}\n"
                       for n in self.prov) + f"prom/blackbox:v1 {digest('x')}\n"

    def __call__(self, url: str, headers: dict):
        import urllib.parse
        self.calls.append((url, dict(headers)))
        u = urllib.parse.urlsplit(url)
        if url == f"https://{REG}/v2/":
            return 401, {"www-authenticate": f'{self.scheme} realm="{self.realm}",service="container_registry"'}, b""
        if url.split("?")[0] == self.realm.split("?")[0]:
            if headers.get("Authorization") != BASIC:
                return 401, {}, b""
            return self.token_status, {}, json.dumps({"token": BEARER}).encode()
        if (u.hostname, u.port) != (REG, None) or headers.get("Authorization") != f"Bearer {BEARER}":
            return 401, {}, b""
        _, _, repo_kind = u.path.partition("/v2/")
        repo, kind, ref = repo_kind.rsplit("/", 2)
        if repo.removeprefix("theorg/observability-") not in self.prov or ref not in self.store:
            return 404, {}, b""
        return 200, {}, self.store[ref]


def registry_cases() -> list[bool]:
    out = []
    good = {n: [(SOURCE, REV)] for n in NAMES}

    def read(reg, tag="latest", missing="", digests_out=None, pulled=None):
        dr.http_get = reg
        text = reg.digests_out(missing) if digests_out is None else digests_out
        bh.ssh = lambda target, cmd, **kw: Done(0, text)
        try:
            return quiet(lambda: with_pull_env(lambda: dr.stack_revision(
                SPEC, tag, REG, reg.pulled() if pulled is None else pulled)))
        finally:
            dr.http_get, bh.ssh = _no_contact, _no_contact

    def stopped(name, needle, reg, **kw):
        return stops(name, needle, lambda: read(reg, **kw))

    reg = StandInRegistry(good)
    rev, printed = read(reg)
    basic_to = [u for u, h in reg.calls if h.get("Authorization", "").startswith("Basic ")]
    bearer_to = {u.split("/v2/")[0] for u, h in reg.calls if h.get("Authorization", "").startswith("Bearer ")}
    out.append(check("registry: 10 theOrg images, one provenance revision each, all R: R (no config label read)",
                     rev == REV and f"revision {REV}" in printed and "10 pulled theOrg images" in printed,
                     repr((rev, printed))))
    shared = reg.pulled() + reg.pulled()[:1] * 2
    rev2, _ = read(StandInRegistry(good), pulled=shared)
    out.append(check("registry: an image `images` lists once per service (the three gateways' one image) "
                     "still matches `digests`, which lists it once", rev2 == REV, repr(rev2)))
    out.append(check("registry: the pull token (Basic) goes only to the token realm on the registry's host, "
                     "over https; the bearer only to that host",
                     basic_to and all(u.startswith(f"https://{REG}/v2/token?") for u in basic_to)
                     and bearer_to == {f"https://{REG}"} and all(u.startswith("https://") for u, _ in reg.calls),
                     repr((basic_to, bearer_to))))
    out.append(check("registry: the pull token is in no URL and not printed",
                     not any(PULL in u for u, _ in reg.calls) and PULL not in printed and BASIC not in printed
                     and BEARER not in printed))
    out.append(check("registry: a pull-scoped token per repository",
                     sorted(u.split("scope=")[1] for u in basic_to)
                     == sorted(f"repository%3Atheorg%2Fobservability-{n}%3Apull" for n in NAMES), repr(basic_to)))
    out.append(check("registry: every manifest and blob is read by its sha256 digest",
                     all(dr.DIGEST.fullmatch(u.rsplit("/", 1)[1]) for u, _ in reg.calls if "/manifests/" in u or "/blobs/" in u)
                     and any("/blobs/" in u for u, _ in reg.calls)))
    out.append(check("registry: a pin that is the images' revision passes",
                     read(StandInRegistry(good), tag=REV[:7])[0] == REV))
    out.append(check("registry: buildkit's v0.2 provenance is read too",
                     read(StandInRegistry(good, predicate="v0.2"))[0] == REV))
    out.append(check("registry: the source as a .git URL, case aside, is theOrg's",
                     read(StandInRegistry({n: [(SOURCE.upper() + ".git", REV)] for n in NAMES}))[0] == REV))
    out.append(check("registry: an image with two digests, each naming exactly R, passes",
                     read(StandInRegistry(good, more={"loki": [(SOURCE, REV)]}))[0] == REV))
    two = "".join(f"{REG}/theorg/observability-{n}:latest {digest(n)}\n" for n in NAMES)
    for name, needle, r, kw in (
            ("a token realm on another host is refused: the pull token is not sent", "no Bearer realm",
             StandInRegistry(good, realm="https://elsewhere.example/v2/token"), {}),
            ("a token realm on the registry host's other port is refused: the pull token is not sent", "no Bearer realm",
             StandInRegistry(good, realm=f"https://{REG}:8443/v2/token"), {}),
            ("a token realm over http is refused", "no Bearer realm",
             StandInRegistry(good, realm=f"http://{REG}/v2/token"), {}),
            ("a Basic challenge (no Bearer realm) is refused", "no Bearer realm",
             StandInRegistry(good, scheme="Basic"), {}),
            ("a theOrg image on a foreign registry host is refused before any request", "not on gitea.example",
             StandInRegistry(good), {"digests_out": two.replace(f"{REG}/theorg/observability-loki", "elsewhere.example/theorg/observability-loki"),
                                     "pulled": [f"{REG}/theorg/observability-{n}:latest" for n in NAMES]}),
            ("`digests` listing other images than `images` pulled is refused before any request", "other theOrg images",
             StandInRegistry(good), {"pulled": [f"{REG}/theorg/observability-{n}:latest" for n in NAMES[1:]]}),
            ("a pulled image `digests` does not list is refused before any request", "other theOrg images",
             StandInRegistry(good), {"pulled": [f"{REG}/theorg/observability-{n}:latest" for n in (*NAMES, "extra")]}),
            ("a digest that is not sha256:<64 hex> is refused before any request", "is not sha256:<64 hex>",
             StandInRegistry(good), {"digests_out": two.replace(digest("loki"), "sha256:" + "1" * 63)}),
            ("a refused pull token stops", "HTTP 401", StandInRegistry(good, token_status=401), {}),
            ("an image with no attestation stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": []}), {}),
            ("an image whose second digest has no attestation (an empty set) stops", "loki:latest: no theOrg revision "
             "in its provenance (1 of 2 digest(s))", StandInRegistry(good, more={"loki": []}), {}),
            ("an image whose two digests name different commits stops", "loki:latest: revisions",
             StandInRegistry(good, more={"loki": [(SOURCE, "b" * 40)]}), {}),
            ("images built from different commits stop", "different commits",
             StandInRegistry({**good, "vector": [(SOURCE, "b" * 40)]}), {}),
            ("one image whose attestations disagree stops", "vector:latest: revisions",
             StandInRegistry({**good, "vector": [(SOURCE, REV), (SOURCE, "b" * 40)]}), {}),
            ("a source that is not theOrg's observability stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": [(f"https://{REG}/grafana/loki", REV)]}), {}),
            ("a source with theOrg's path on another host stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": [("https://elsewhere.example/theOrg/observability", REV)]}), {}),
            ("a source whose path only ends in theorg/observability stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": [(f"https://{REG}/x/theorg/observability", REV)]}), {}),
            ("a revision that is not 40 hex stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": [(SOURCE, "f599ebc5")]}), {}),
            ("a pin the provenance does not name stops", "as their build revision", StandInRegistry(good),
             {"tag": "b" * 40}),
            ("an image with no registry digest on d06 stops", "vector:latest: no registry digest", StandInRegistry(good),
             {"missing": "vector"}),
            ("an index whose bytes do not hash to its digest stops", "does not hash to its digest",
             StandInRegistry(good, tamper="loki"), {}),
            ("an answer that is not understood stops", "not understood",
             StandInRegistry(good, index_body=b"<html>"), {})):
        r_calls = r.calls
        out.append(stopped(f"registry: {name}, nothing minted", needle, r, **kw))
        if "realm" in name or "Basic challenge" in name or "before any request" in name:
            out.append(check(f"registry: {name.split(':')[0]}: no request carried an Authorization header",
                             all("Authorization" not in h for _, h in r_calls)
                             and not any("elsewhere" in u for u, _ in r_calls), repr(r_calls)))
        if "before any request" in name:
            out.append(check(f"registry: {name}: no request at all", r_calls == [], repr(r_calls)))
    q = StandInRegistry(good, realm=f"https://{REG}/v2/token?x=1")
    read(q)
    out.append(check("registry: a realm with its own query string keeps it",
                     any(u.startswith(f"https://{REG}/v2/token?x=1&service=") for u, _ in q.calls)))
    return out


VIKUNJA_TOKEN = "secret/v2/vikunja/alert-tokens/svc-alert-relay-d06"   # outside KV (secrets-vault#46)
LOKI_ACCOUNT = "own/loki-clients/alert-relay"   # asyla's own Loki account (loki_accounts.py)


def service_block(compose: str, name: str) -> list[str]:
    """The stripped, uncommented lines of compose.yml's service NAME (indent 2), up to the next one."""
    lines, inside = [], False
    for ln in compose.splitlines():
        if ln.startswith("  ") and not ln.startswith("   ") and ln.rstrip().endswith(":") \
                and not ln.lstrip().startswith("#"):
            inside = ln.strip() == f"{name}:"
            continue
        if ln and not ln.startswith(" "):
            inside = False
        if inside and ln.strip() and not ln.lstrip().startswith("#"):
            lines.append(ln.strip())
    return lines


def shell_words(sh: str, var: str) -> list[str]:
    """The words of observability.sh's top-level VAR="..." assignment."""
    import re
    m = re.search(rf'^{var}="([^"]*)"$', sh, re.M)
    return m.group(1).split() if m else []


def token_vars(sh: str) -> dict[str, str]:
    """observability.sh token_var's case arms: service -> variable."""
    import re
    body = sh.split("\ntoken_var() {", 1)[1].split("\n}", 1)[0] if "\ntoken_var() {" in sh else ""
    return dict(re.findall(r"^\s*([a-z][a-z-]*)\) echo ([A-Z_]+) ;;$", body, re.M))


def compose_networks(compose: str) -> dict[str, dict]:
    """Every service's networks, as {network: aliases} (lines of indent 6 and 10 under networks:),
    and the top-level networks block as {name: its stripped lines} under the key ''."""
    services: dict[str, dict] = {}
    top: dict[str, list[str]] = {}
    section, svc, inside, net = "", "", False, ""
    for ln in compose.splitlines():
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip())
        text = ln.strip()
        if indent == 0:
            section = text.rstrip(":")
            continue
        if section == "services":
            if indent == 2:
                svc, inside = text.rstrip(":"), False
                services[svc] = {}
            elif indent == 4:
                inside = text == "networks:"
            elif inside and indent == 6:
                net = text.lstrip("- ").split(":")[0]
                services[svc][net] = []
            elif inside and indent == 10 and text.startswith("- "):
                services[svc][net].append(text[2:])
        elif section == "networks":
            if indent == 2:
                net = text.rstrip(":")
                top[net] = []
            else:
                top[net].append(text)
    return {**services, "": top}


# The three gateways (asyla #1268: option B, items 3 and 4): component, its registry, its
# observability.sh accounts variable, LOKI_GATEWAY_MODE and LOKI_UPSTREAM.
GATEWAYS = [
    ("loki-gateway", "loki-clients.toml", "LOKI_GATEWAY_ACCOUNTS", None, "http://loki:3100"),
    ("prometheus-write-gateway", "prometheus-write-clients.toml", "PROMETHEUS_WRITE_GATEWAY_ACCOUNTS",
     "remote-write", "http://prometheus-ingest:9090"),
    ("pushgateway-gateway", "pushgateway-clients.toml", "PUSHGATEWAY_GATEWAY_ACCOUNTS", "pushgateway",
     "http://pushgateway:9091"),
]
# Every service that joins more than observability-net, or not it, with its aliases; every other
# service is on observability-net alone.
WANT_NETS = {
    "loki-gateway": {"observability-net": [], "loki-edge": ["loki-gateway-edge"]},
    "prometheus-write-gateway": {"observability-net": [], "ingest": [], "loki-edge": ["prometheus-write-gateway-edge"]},
    "pushgateway-gateway": {"observability-net": [], "push": [], "loki-edge": ["pushgateway-gateway-edge"]},
    "prometheus": {"observability-net": [], "ingest": [], "push": []},
    "prometheus-ingest": {"ingest": []},
    "pushgateway": {"push": []},
}
# The external networks: compose key, Docker name, who joins it.
WANT_EXTERNAL = {
    # Historical name (loki-gateway's alone in items 1-2): it carries all three gateways' hops.
    "loki-edge": ("observability-loki-edge", ["loki-gateway", "prometheus-write-gateway", "pushgateway-gateway"]),
    "ingest": ("observability-ingest", ["prometheus", "prometheus-ingest", "prometheus-write-gateway"]),
    "push": ("observability-push", ["prometheus", "pushgateway", "pushgateway-gateway"]),
}


def gateways_cases() -> list[bool]:
    """The three gateways: each registry matches its IDENTITIES line, its accounts literal and its
    compose block; the networks, who joins each, internal and external; the ingest Prometheus, its
    federation and the remote-write gateway's healthcheck; the pushgateway with no port; no gateway
    on a replica; restart's network check."""
    import re
    import tomllib
    compose = (dr.HERE / "compose.yml").read_text()
    sh = (dr.HERE / "observability.sh").read_text()
    ids = {c: (e, rs) for c, e, rs in dr.IDENTITIES}
    nets = compose_networks(compose)
    top = nets[""]
    services = {s: n for s, n in nets.items() if s}
    readers, replica, tvars = shell_words(sh, "VAULT_READERS"), shell_words(sh, "REPLICA_SERVICES"), token_vars(sh)
    app = [a for a in bh.load_spec("d06").get("app", []) if a.get("name") == "observability"]
    out = []
    for comp, toml, var, mode, upstream in GATEWAYS:
        clients = tomllib.loads((dr.HERE / toml).read_text())["clients"]
        names = list(clients)
        stem = toml.removesuffix(".toml")
        env, records = ids.get(comp, ("", []))
        m = re.search(rf'^{var}="([^"]*)"$', sh, re.M)
        block = service_block(compose, comp)
        out += [
            check(f"gateways {comp}: IDENTITIES records are every account of {toml}, under own/{stem}/, in its order",
                  env == tvars.get(comp) and env.endswith("_OPENBAO_WRAPPED_TOKEN")
                  and records == [f"own/{stem}/{n}" for n in names] and names == sorted(names) and bool(names),
                  repr((env, records))),
            check(f"gateways {comp}: observability.sh {var} = {toml}'s name:scope, in name order",
                  bool(m) and m.group(1) == ",".join(f"{n}:{clients[n]['scope'][0]}" for n in names),
                  repr(m.group(1) if m else None)),
            check(f"gateways {comp}: compose passes {var} as its LOKI_GATEWAY_ACCOUNTS, its own token and prefix, "
                  "TLS off, its mode and upstream, read_only, cap_drop ALL, no ports",
                  f"LOKI_GATEWAY_ACCOUNTS: ${{{var}:?}}" in block
                  and f"OPENBAO_WRAPPED_TOKEN: ${{{env}:-}}" in block
                  and f'LOKI_CLIENTS_KV_PREFIX: "secret/hubs/asyla/own/{stem}"' in block
                  and 'LOKI_GATEWAY_TLS: "off"' in block and f'LOKI_UPSTREAM: "{upstream}"' in block
                  and (f'LOKI_GATEWAY_MODE: "{mode}"' in block if mode else not any("LOKI_GATEWAY_MODE" in ln for ln in block))
                  and "read_only: true" in block and "- ALL" in block
                  and not any(ln.startswith(("ports:", "extra_hosts:")) for ln in block), repr(block)),
            check(f"gateways {comp}: a vault reader, not a replica service (it reads production's OpenBao)",
                  comp in readers and comp not in replica, repr((readers, replica))),
        ]
    prefixes = [f"own/{t.removesuffix('.toml')}/" for _, t, *_ in GATEWAYS]
    out.append(check("gateways: no two gateways share a record prefix, and none reads another's",
                     all(sum(r.startswith(p) for p in prefixes) == 1 and r.startswith(prefixes[i])
                         for i, (c, *_) in enumerate(GATEWAYS) for r in ids[c][1]), repr(prefixes)))

    # Networks: who joins each, internal and external, the aliases.
    out.append(check("networks: each service's networks and aliases are as named; every other is on "
                     "observability-net alone",
                     all(services.get(s) == n for s, n in WANT_NETS.items())
                     and all(n == {"observability-net": []} for s, n in services.items() if s not in WANT_NETS),
                     repr({s: n for s, n in services.items() if n != {"observability-net": []}})))
    out.append(check("networks: observability-net is the stack's own bridge; the other three are external",
                     sorted(top) == sorted(["observability-net", *WANT_EXTERNAL])
                     and top["observability-net"] == ["driver: bridge"], repr(top)))
    for key, (name, joiners) in WANT_EXTERNAL.items():
        out.append(check(f"networks: {key} is the external {name} (no driver or internal in compose), "
                         f"joined by {', '.join(joiners)} only",
                         sorted(top.get(key, [])) == sorted([f"name: {name}", "external: true"])
                         and sorted(s for s, n in services.items() if key in n) == joiners,
                         repr((top.get(key), sorted(s for s, n in services.items() if key in n)))))
    live = [ln for ln in compose.splitlines() if not ln.lstrip().startswith("#")]
    aliases = [a for n in services.values() for al in n.values() for a in al]
    out.append(check("networks: three aliases, each on edge alone and in one place",
                     sorted(aliases) == sorted(f"{c}-edge" for c, *_ in GATEWAYS)
                     and all(sum(f"{c}-edge" in ln for ln in live) == 1 for c, *_ in GATEWAYS)
                     and all(not al for s, n in services.items() for k, al in n.items() if k != "loki-edge"),
                     repr(aliases)))
    nw = shell_words(sh, "NETWORKS")
    fn = shell_function(sh, "ensure_networks")
    up_fn = shell_function(sh, "do_up")
    up_body = [ln.strip() for ln in up_fn.splitlines()[1:] if ln.strip() and not ln.strip().startswith(("local ", "#"))]
    restart_arm = sh.split("\n    restart)", 1)[1].split(";;", 1)[0] if "\n    restart)" in sh else ""
    out += [
        check("networks: observability.sh NETWORKS are compose.yml's three external names",
              sorted(nw) == sorted(n for n, _ in WANT_EXTERNAL.values()), repr(nw)),
        check("networks: ensure_networks makes each missing one --internal and refuses one that is not internal",
              'for net in $NETWORKS; do' in fn and 'docker network inspect "$net" >/dev/null' in fn
              and 'docker network create --internal --driver bridge "$net"' in fn
              and "docker network inspect -f '{{.Internal}}' \"$net\"" in fn
              and '[ "$got" = "true" ] || die "network $net exists but is not internal' in fn, fn),
        check("networks: do_up calls ensure_networks before anything else, so before every up "
              "(restart's too), replica or not, token or not",
              bool(up_body) and up_body[0] == "ensure_networks"
              and sh.count("run_compose up ") == up_fn.count("run_compose up ") == 2
              and "&& do_up" in restart_arm, repr(up_body[:3])),
        check("networks: restart calls ensure_networks before it takes the stack down",
              "images_ready && ensure_networks && run_compose down --remove-orphans && do_up" in restart_arm,
              repr(restart_arm[-200:])),
        check("networks: no ensure_edge_network is left, and the edge network is not renamed",
              "ensure_edge_network" not in sh + compose and "observability-edge" not in sh + compose),
        check("networks: nothing in observability.sh removes a network (down leaves them)",
              "network rm" not in "\n".join(ln for ln in sh.splitlines() if "die " not in ln)
              and "down --remove-orphans -v" not in sh),
    ]

    # The ingest Prometheus (theOrg compose.ingest.yml at 04f31709), its federation and the gateway in
    # front of it; the pushgateway with no port.
    receivers = sorted(s for s in services if any("--web.enable-remote-write-receiver" in ln
                                                   for ln in service_block(compose, s)))
    profiled = {s: [ln for ln in service_block(compose, s) if ln.startswith("profiles:")] for s in services}
    pwg = service_block(compose, "prometheus-write-gateway")
    ing = service_block(compose, "prometheus-ingest")
    prom = service_block(compose, "prometheus")
    gw_fn = shell_function(sh, "check_gateway")
    stack_jobs = sh.split('STACK_JOBS="', 1)[1].split('"', 1)[0].split()
    verify_fn = shell_function(sh, "do_verify")
    out += [
        check("ingest: only prometheus-ingest (and prometheus-trends, emporia-collector's, on "
              "observability-net) has the remote-write receiver flag; prometheus has none",
              receivers == ["prometheus-ingest", "prometheus-trends"]
              and not any("remote-write-receiver" in ln for ln in prom),
              repr(receivers)),
        check("ingest: no service has a profile (prometheus-ingest starts with the stack)",
              not any(profiled.values()), repr(profiled)),
        check("ingest: observability.sh never enables a profile (no --profile, no COMPOSE_PROFILES)",
              "--profile" not in sh and "COMPOSE_PROFILES" not in sh),
        check("ingest: prometheus-ingest is the operations image in ingest mode (PROMETHEUS_MODE=ingest, "
              "ingest.yml, the receiver, 1d/2GB), on observability-ingest only, data under OBSERVABILITY_ROOT",
              "image: gitea.asyla.org/theorg/observability-prometheus:${OBSERVABILITY_TAG:?}" in ing
              and "PROMETHEUS_MODE: ingest" in ing
              and "- --config.file=/etc/prometheus/ingest.yml" in ing
              and "- --web.enable-remote-write-receiver" in ing
              and "- --storage.tsdb.retention.time=${INGEST_RETENTION_TIME:-1d}" in ing
              and "- --storage.tsdb.retention.size=${INGEST_RETENTION_SIZE:-2GB}" in ing
              and services.get("prometheus-ingest") == {"ingest": []}
              and any(ln.startswith("test:") and "/-/healthy" in ln for ln in ing)
              and not any(ln.startswith("ports:") for ln in ing), repr(ing)),
        check("ingest: prometheus federates prometheus-ingest (FEDERATE_INGEST=true, THEORG_SCRAPE=false, "
              "FEDERATE_INGEST_HOST/_PORT)",
              'FEDERATE_INGEST: "true"' in prom and 'THEORG_SCRAPE: "false"' in prom
              and 'FEDERATE_INGEST_HOST: "prometheus-ingest"' in prom
              and 'FEDERATE_INGEST_PORT: "9090"' in prom
              and not any("MONITOR_THEORG" in ln for ln in prom), repr(prom)),
        check("ingest: prometheus-write-gateway has loki-gateway's healthcheck and depends_on "
              "prometheus-ingest healthy",
              'test: ["CMD", "/loki-gateway", "healthcheck"]' in pwg and "disable: true" not in pwg
              and pwg[pwg.index("depends_on:") + 1:pwg.index("depends_on:") + 3]
              == ["prometheus-ingest:", "condition: service_healthy"] if "depends_on:" in pwg else False,
              repr(pwg)),
        check("ingest: check_gateway wants prometheus-write-gateway's /ready 200 (no 502 left)",
              "check_one_gateway prometheus-write-gateway 200 POST /api/v1/write" in gw_fn
              and "502" not in gw_fn and "ready=" not in gw_fn, gw_fn),
        check("ingest: STACK_JOBS has ingest-federate, whose target is prometheus-ingest",
              "ingest-federate:prometheus-ingest" in stack_jobs, repr(stack_jobs)),
        check("ingest: verify proves prometheus-1 reaches prometheus-ingest by the federate target, "
              "not a busybox wget (its lookup fails on the internal network)",
              "prometheus-ingest:9090/-/healthy" not in verify_fn, verify_fn[:200]),
        check("push: the pushgateway has no ports",
              bool(service_block(compose, "pushgateway"))
              and not any(ln.startswith("ports:") for ln in service_block(compose, "pushgateway")),
              repr(service_block(compose, "pushgateway"))),
        check("push: STACK_JOBS keeps the pushgateway job (prometheus scrapes it on push)",
              "pushgateway:pushgateway" in sh.split('STACK_JOBS="', 1)[1].split('"', 1)[0]),
        check("verify: each gateway's anonymous route: loki a query, remote-write a POST, the pushgateway a PUT",
              "check_one_gateway loki-gateway 200 GET /loki/api/v1/labels" in sh
              and "check_one_gateway prometheus-write-gateway 200 POST /api/v1/write" in sh
              and "check_one_gateway pushgateway-gateway 200 PUT /metrics/job/verify" in sh),
        check("replica: no gateway on a replica; prometheus, prometheus-ingest (ingest-federate reads it) "
              "and the pushgateway are",
              not {c for c, *_ in GATEWAYS} & set(replica)
              and {"prometheus", "prometheus-ingest", "pushgateway"} <= set(replica), repr(replica)),
        check("tokens: token_var, IDENTITIES and d06/host.toml start_env_optional name the same variables",
              tvars == {c: e for c, e, _ in dr.IDENTITIES}
              and len(app) == 1 and sorted(tvars.values()) == sorted(app[0].get("start_env_optional", []))
              and sorted(tvars) == sorted(readers), repr((tvars, app[:1]))),
    ]
    return out


def gateway_cases() -> list[bool]:
    """loki-gateway (option B, asyla #1268): its token reads every account of loki-clients.toml,
    d06/host.toml sends its variable, and compose.yml runs it plain HTTP with no port and asyla's
    prefix, reached by Caddy only on edge; the operations prometheus has no remote-write receiver."""
    import tomllib
    names = list(tomllib.loads((dr.HERE / "loki-clients.toml").read_text())["clients"])
    ids = {c: (e, rs) for c, e, rs in dr.IDENTITIES}
    env, records = ids.get("loki-gateway", ("", []))
    app = [a for a in bh.load_spec("d06").get("app", []) if a.get("name") == "observability"]
    compose = (dr.HERE / "compose.yml").read_text()
    gw = service_block(compose, "loki-gateway")
    prom = service_block(compose, "prometheus")
    sh = (dr.HERE / "observability.sh").read_text()
    readers, replica, tvars = shell_words(sh, "VAULT_READERS"), shell_words(sh, "REPLICA_SERVICES"), token_vars(sh)
    return [
        check("gateway: loki-gateway is a vault reader and not a replica service (it reads production's OpenBao)",
              "loki-gateway" in readers and "loki-gateway" not in replica and bool(replica), repr((readers, replica))),
        check("gateway: token_var maps exactly the VAULT_READERS services",
              bool(readers) and sorted(tvars) == sorted(readers), repr((tvars, readers))),
        check("gateway: token_var's variables are IDENTITIES' env names, service by service",
              tvars == {c: e for c, e, _ in dr.IDENTITIES}, repr((tvars, dr.IDENTITIES))),
        check("gateway: token_var's variables are d06/host.toml observability start_env_optional",
              len(app) == 1 and sorted(tvars.values()) == sorted(app[0].get("start_env_optional", [])),
              repr((tvars, app[:1]))),
        check("gateway: compose.yml prometheus has no remote-write receiver flag",
              bool(prom) and not any("remote-write" in ln for ln in prom), repr(prom)),
        check("gateway: loki-clients.toml has the 13 accounts, in name order",
              len(names) == 13 and names == sorted(names), repr(names)),
        check("gateway: IDENTITIES has loki-gateway with every account's own/loki-clients record",
              env == "LOKI_GATEWAY_OPENBAO_WRAPPED_TOKEN"
              and records == [f"own/loki-clients/{n}" for n in names], repr(records)),
        check("gateway: deploy_role.loki_client_names reads the same names",
              dr.loki_client_names(dr.HERE / "loki-clients.toml") == names),
        check("gateway: d06/host.toml observability start_env_optional names its variable",
              len(app) == 1 and "LOKI_GATEWAY_OPENBAO_WRAPPED_TOKEN" in app[0].get("start_env_optional", []),
              repr(app[:1])),
        check("gateway: compose.yml runs it with TLS off, asyla's prefix, its token and accounts, no ports",
              bool(gw) and 'LOKI_GATEWAY_TLS: "off"' in gw
              and 'LOKI_CLIENTS_KV_PREFIX: "secret/hubs/asyla/own/loki-clients"' in gw
              and "OPENBAO_WRAPPED_TOKEN: ${LOKI_GATEWAY_OPENBAO_WRAPPED_TOKEN:-}" in gw
              and "LOKI_GATEWAY_ACCOUNTS: ${LOKI_GATEWAY_ACCOUNTS:?}" in gw
              and 'LOKI_UPSTREAM: "http://loki:3100"' in gw
              and not any(ln.startswith(("ports:", "extra_hosts:")) or "loki-ca" in ln or "STEP" in ln
                          for ln in gw), repr(gw)),
    ]


def relay_records_cases() -> list[bool]:
    """alert-relay's token reads its SMTP login, the Watchdog's ping URL, the Vikunja token (by its
    full path, outside the hub's KV), the delivery check's ping URL and its Loki query account (a
    path under the hub's own/), each named in compose.yml (the Vikunja token, the delivery ping URL
    and the Loki account by their own settings; the Loki account by its field password, the rest
    by value); the relay queries Loki at loki:3100; no Gitea setting is left; alerts go to Vikunja
    project 170 (ALERT_PROJECTS); and the watchdog piece is on."""
    records = {c: rs for c, _, rs in dr.IDENTITIES}["alert-relay"]
    compose = (dr.HERE / "compose.yml").read_text()
    live = [ln.strip() for ln in compose.splitlines() if not ln.lstrip().startswith("#")]
    sh = (dr.HERE / "observability.sh").read_text()
    field = {LOKI_ACCOUNT: "password"}
    return [
        check("relay: its records are the SMTP login, the Watchdog's ping URL, the Vikunja token, "
              "the delivery ping URL and its Loki query account",
              records == ["smtp-relay-username", "smtp-relay-password", "observability-watchdog-ping-url",
                          VIKUNJA_TOKEN, "observability-delivery-ping-url", LOKI_ACCOUNT]),
        check("relay: compose.yml names each of its records (a secret/ one by its own path) with its field",
              all(any(ln.startswith("ALERT_RELAY_") and f'"{dr.kv_path(r)}#{field.get(r, "value")}"' in ln
                      for ln in live)
                  for r in records)
              and all(dr.kv_path(r) == (r if r.startswith("secret/") else f"secret/hubs/asyla/{r}")
                      for r in records)),
        check("relay: compose.yml gives the Vikunja token and the delivery ping URL their settings",
              f'ALERT_RELAY_VIKUNJA_KV: "{VIKUNJA_TOKEN}#value"' in live
              and 'ALERT_RELAY_DELIVERY_PING_KV: "secret/hubs/asyla/observability-delivery-ping-url#value"'
              in live),
        check("relay: compose.yml gives the Loki account its setting (field password) and queries loki:3100",
              'ALERT_RELAY_LOKI_KV: "secret/hubs/asyla/own/loki-clients/alert-relay#password"' in live
              and 'LOKI_QUERY_URL: "http://loki:3100"' in live
              and sum(ln.startswith("LOKI_QUERY_URL:") for ln in live) == 1
              and not any(ln.startswith("LOKI_QUERY_USER:") for ln in live)),
        check("relay: verify wants loki_password held (check_tokened)",
              'names="delivery_ping_url loki_password vikunja_token"' in sh),
        check("relay: compose.yml has no Gitea setting left (forge token, URL, alert repo, repos)",
              not any(ln.startswith(k) for ln in live
                      for k in ("ALERT_RELAY_FORGE_KV", "GITEA_ALERT_REPO", "GITEA_URL", "ALERT_REPOS"))),
        check("relay: alerts go to Vikunja project 170 by default, theOrg's to 169 (compose.yml takes "
              "ALERT_PROJECTS from observability.sh; asyla first, so the default)",
              "ALERT_PROJECTS: ${ALERT_PROJECTS:?}" in live and '\nALERT_PROJECTS="asyla=170 theOrg=169"\n' in sh),
        check("relay: the watchdog piece is on in observability.sh",
              '\nALERT_WATCHDOG_PING="on"\n' in sh),
    ]


def shell_function(sh: str, name: str) -> str:
    """observability.sh's top-level function NAME, from `NAME() {` to its closing `}` line."""
    import re
    m = re.search(rf"^{name}\(\) \{{\n.*?^\}}$", sh, re.M | re.S)
    if not m:
        raise AssertionError(f"observability.sh has no function {name}")
    return m.group(0)


# do_alert_test's contacts, stubbed: docker records its arguments one per line (amtool's labels
# among them) and answers nothing; the relay's log names task 42 in project $STUB_PID; relay_logql
# reads 0 lines, then 1. date -d is GNU only, so it answers a fixed time.
ALERT_TEST_STUBS = r'''
SERVING_HOST=d06
is_replica() { return 1; }
service_state() { echo "running (healthy)"; }
info() { echo "[INFO] $*"; }
sleep() { :; }
date() { case "$*" in *-d*) echo 2026-11-22T00:00:00Z ;; *) command date "$@" ;; esac; }
docker() { printf '%s\n' "$@" >> "$STUB/docker"; }
alert_test_fingerprint() { echo abc123; }
relay_logql() {
  if [ -e "$STUB/logql" ]; then echo "lines=1 empty=0 error=0 unconfigured=0"
  else echo seen > "$STUB/logql"; echo "lines=0 empty=0 error=0 unconfigured=0"; fi
}
wait_relay_task() { if [ "$3" = opened ]; then echo "42 $STUB_PID"; fi; return 0; }
'''


def alert_test_cases() -> list[bool]:
    """alert-test, run offline: observability.sh's own default_project_id, alert_test_project and
    do_alert_test in a local bash with every contact stubbed. Unset ALERT_TEST_PROJECT is the
    default (170) with no alert_repo label; theOrg sets alert_repo="theOrg/observability" and
    wants 169; a name not in ALERT_PROJECTS is refused before any contact."""
    import re
    sh = (dr.HERE / "observability.sh").read_text()
    projects = re.search(r'^ALERT_PROJECTS="[^"]*"$', sh, re.M).group(0)
    funcs = "\n".join(shell_function(sh, n) for n in ("default_project_id", "alert_test_project", "do_alert_test"))

    def run(call: str, project: str | None, pid: str = "") -> tuple[int, str, str, list[str]]:
        with tempfile.TemporaryDirectory() as stub:
            env = {"PATH": os.environ["PATH"], "STUB": stub, "STUB_PID": pid}
            if project is not None:
                env["ALERT_TEST_PROJECT"] = project
            p = REAL_RUN(["bash", "-c", f"set -euo pipefail\n{projects}\n{funcs}\n{ALERT_TEST_STUBS}\n{call}"],
                         env=env, capture_output=True, text=True, timeout=60)
            calls = Path(stub, "docker").read_text().splitlines() if Path(stub, "docker").exists() else []
        return p.returncode, p.stdout, p.stderr, calls

    out = []
    rc, so, se, _ = run("default_project_id", None)
    out.append(check("alert-test: default_project_id is 170 (asyla, the first ALERT_PROJECTS entry)",
                     rc == 0 and so == "170\n", f"rc={rc} out={so!r} err={se!r}"))
    rc, so, se, calls = run("do_alert_test", None, "170")
    out.append(check("alert-test: unset ALERT_TEST_PROJECT wants the default 170, no alert_repo label",
                     rc == 0 and "alertname=AsylaAlertRelayTest" in calls
                     and not any(c.startswith("alert_repo=") for c in calls)
                     and "alert-test OK: task 42 in Vikunja project 170" in so, f"rc={rc} err={se!r}"))
    rc, so, se, calls = run("do_alert_test", "theOrg", "169")
    out.append(check('alert-test: ALERT_TEST_PROJECT=theOrg sets alert_repo="theOrg/observability" and wants 169',
                     rc == 0 and 'alert_repo="theOrg/observability"' in calls
                     and "alert-test OK: task 42 in Vikunja project 169" in so, f"rc={rc} err={se!r}"))
    rc, so, se, calls = run("do_alert_test", "theorg", "169")
    out.append(check("alert-test: the name matches case-insensitively; the label takes ALERT_PROJECTS' spelling",
                     rc == 0 and 'alert_repo="theOrg/observability"' in calls, f"rc={rc} err={se!r}"))
    rc, so, se, calls = run("do_alert_test", "theOrg", "170")
    out.append(check("alert-test: theOrg's task in the default 170 fails (it wants 169)",
                     rc == 1 and "task 42 is in project 170, not project 169 (theOrg, ALERT_TEST_PROJECT)" in se,
                     f"rc={rc} err={se!r}"))
    rc, so, se, calls = run("do_alert_test", "nope", "170")
    out.append(check("alert-test: a name not in ALERT_PROJECTS is refused, naming the entries, before any contact",
                     rc == 1 and "ALERT_TEST_PROJECT 'nope' is not in ALERT_PROJECTS (asyla=170 theOrg=169)" in se
                     and calls == [], f"rc={rc} err={se!r} calls={calls}"))
    return out


def data_dirs_cases() -> list[bool]:
    """Every bind volume compose.yml puts under OBSERVABILITY_ROOT is made by ensure_dirs and owned
    by own_dirs, prometheus-ingest-data among them as nobody (65534) like the other Prometheus data
    directories (asyla #1268)."""
    import re
    compose = (dr.HERE / "compose.yml").read_text()
    sh = (dr.HERE / "observability.sh").read_text()
    binds = re.findall(r'device: "\$\{OBSERVABILITY_ROOT:\?\}/([a-z-]+)"', compose)
    made, owned = shell_function(sh, "ensure_dirs"), shell_function(sh, "own_dirs")
    nobody = re.search(r"chown 65534:65534 ([^']*)'", owned)
    nobody_dirs = nobody.group(1).split() if nobody else []
    return [
        check("dirs: compose.yml binds prometheus-ingest-data under OBSERVABILITY_ROOT",
              "prometheus-ingest-data" in binds, repr(binds)),
        check("dirs: ensure_dirs makes every bind volume compose.yml names",
              bool(binds) and all(f'"$OBSERVABILITY_ROOT/{b}"' in made for b in binds), repr((binds, made))),
        check("dirs: own_dirs owns every bind volume compose.yml names",
              bool(binds) and all(f"/data/{b}" in owned for b in binds), repr((binds, owned))),
        check("dirs: own_dirs gives prometheus-ingest-data to 65534 with the other Prometheus data directories",
              all(f"/data/{b}" in nobody_dirs for b in
                  ("prometheus-data", "prometheus-trends-data", "prometheus-ingest-data")), repr(nobody_dirs)),
    ]


# check_one_gateway's one contact, docker, as a fake on PATH: it records each call's arguments on
# one line and answers as GNU wget -S would, the status line on stderr ($STUB_READY for /ready,
# $STUB_WRITE for anything else), exiting 8 (wget's server error) when the status is not 2xx.
FAKE_DOCKER = r'''#!/bin/sh
printf '%s\n' "$*" >> "$STUB/docker"
case "$*" in
  */ready) code="$STUB_READY" ;;
  *) code="$STUB_WRITE" ;;
esac
echo "  HTTP/1.1 $code Stub" >&2
case "$code" in 2*) exit 0 ;; *) exit 8 ;; esac
'''

# check_gateway's other names: service_state is missing for a service not in $STUB_SERVICES.
GATEWAY_STUBS = r'''
info() { echo "[INFO] $*"; }
service_state() { case " $STUB_SERVICES " in *" $1 "*) echo "running (healthy)" ;; *) echo missing ;; esac; }
'''


def gateway_check_cases() -> list[bool]:
    """verify's gateway check, run offline: observability.sh's own gateway_status, check_one_gateway
    and check_gateway in a local bash with docker a fake on PATH. /ready 200 and an anonymous write
    401 pass; an anonymous write 200 fails; check_gateway wants prometheus-write-gateway's /ready
    200, with prometheus-ingest's container or without, and fails on 502. The fake gets wget's
    --method and --body-data for the write, and neither for /ready."""
    sh = (dr.HERE / "observability.sh").read_text()
    funcs = "\n".join(shell_function(sh, n) for n in ("gateway_status", "check_one_gateway", "check_gateway"))

    def run(call: str, ready: str, write: str, services: str = "") -> tuple[int, str, str, list[str]]:
        with tempfile.TemporaryDirectory() as stub:
            fake = Path(stub, "bin", "docker")
            fake.parent.mkdir()
            fake.write_text(FAKE_DOCKER)
            fake.chmod(0o755)
            env = {"PATH": f"{fake.parent}:{os.environ['PATH']}", "STUB": stub, "STUB_READY": ready,
                   "STUB_WRITE": write, "STUB_SERVICES": services}
            p = REAL_RUN(["bash", "-c", f"set -euo pipefail\n{funcs}\n{GATEWAY_STUBS}\n{call}"],
                         env=env, capture_output=True, text=True, timeout=60)
            calls = Path(stub, "docker").read_text().splitlines() if Path(stub, "docker").exists() else []
        return p.returncode, p.stdout, p.stderr, calls

    wget = "exec vector-1 wget -S -O /dev/null -T 10 -t 1"
    gw = "prometheus-write-gateway"
    want = [f"{wget} http://{gw}:3100/ready", f"{wget} --method=POST --body-data= http://{gw}:3100/api/v1/write"]
    out = []
    rc, so, se, calls = run(f"check_one_gateway {gw} 200 POST /api/v1/write", "200", "401")
    out.append(check("gateway check: /ready 200 and an anonymous write 401 pass",
                     rc == 0 and f"{gw}: /ready 200 with no account" in so
                     and f"{gw}: POST /api/v1/write with no account 401" in so, f"rc={rc} out={so!r} err={se!r}"))
    out.append(check("gateway check: the fake gets no --method for /ready, --method=POST --body-data= for the write",
                     calls == want, repr(calls)))
    rc, so, se, calls = run(f"check_one_gateway {gw} 200 POST /api/v1/write", "200", "200")
    out.append(check("gateway check: an anonymous write 200 fails",
                     rc == 1 and f"{gw}: POST /api/v1/write with no account answers '200', not 401" in se,
                     f"rc={rc} out={so!r} err={se!r}"))
    rc, so, se, calls = run("check_gateway", "200", "401", f"{gw} prometheus-ingest")
    out.append(check("gateway check: check_gateway passes prometheus-write-gateway's /ready 200 and anonymous write 401",
                     rc == 0 and f"{gw}: /ready 200 with no account" in so and calls == want,
                     f"rc={rc} out={so!r} err={se!r} calls={calls}"))
    for services in (f"{gw} prometheus-ingest", gw):
        rc, so, se, calls = run("check_gateway", "502", "401", services)
        out.append(check(f"gateway check: check_gateway fails prometheus-write-gateway's /ready 502 "
                         f"({'with' if 'ingest' in services else 'without'} a prometheus-ingest container)",
                         rc == 1 and f"{gw}: /ready answers '502', not 200" in se and "not started" not in so,
                         f"rc={rc} out={so!r} err={se!r}"))
    return out


# FAKE_DOCKER with docker inspect answered as Docker 29 does on d06 (asyla #1268): a container
# named in $STUB_RUNNING (without its -1) is "running healthy"; any other prints an empty line to
# stdout, an error to stderr, and exits 1. Inspect calls are not recorded.
FAKE_DOCKER_INSPECT = r'''#!/bin/sh
if [ "$1" = inspect ]; then
  for a; do name="$a"; done
  case " $STUB_RUNNING " in *" ${name%-1} "*) echo "running healthy"; exit 0 ;; esac
  echo
  echo "Error: No such object: $name" >&2
  exit 1
fi
''' + FAKE_DOCKER.split("\n", 1)[1]


def service_state_cases() -> list[bool]:
    """observability.sh's own service_state, run offline with docker a fake on PATH: a missing
    container (an empty line on stdout, then exit 1) is exactly "missing", a running one is its
    state (verify failed on d06 when "missing" came out as "\\nmissing"); and check_gateway with the
    real service_state checks a running prometheus-write-gateway (/ready 200) and skips a missing one."""
    sh = (dr.HERE / "observability.sh").read_text()
    funcs = "\n".join(shell_function(sh, n)
                      for n in ("service_state", "gateway_status", "check_one_gateway", "check_gateway"))

    def run(call: str, running: str, ready: str = "200", write: str = "401") -> tuple[int, str, str, list[str]]:
        with tempfile.TemporaryDirectory() as stub:
            fake = Path(stub, "bin", "docker")
            fake.parent.mkdir()
            fake.write_text(FAKE_DOCKER_INSPECT)
            fake.chmod(0o755)
            env = {"PATH": f"{fake.parent}:{os.environ['PATH']}", "STUB": stub, "STUB_RUNNING": running,
                   "STUB_READY": ready, "STUB_WRITE": write}
            p = REAL_RUN(["bash", "-c", f"set -euo pipefail\n{funcs}\ninfo() {{ echo \"[INFO] $*\"; }}\n{call}"],
                         env=env, capture_output=True, text=True, timeout=60)
            calls = Path(stub, "docker").read_text().splitlines() if Path(stub, "docker").exists() else []
        return p.returncode, p.stdout, p.stderr, calls

    gw = "prometheus-write-gateway"
    wget = "exec vector-1 wget -S -O /dev/null -T 10 -t 1"
    want = [f"{wget} http://{gw}:3100/ready", f"{wget} --method=POST --body-data= http://{gw}:3100/api/v1/write"]
    out = []
    rc, so, se, _ = run("service_state prometheus-ingest", gw)
    out.append(check("service_state: a missing container (empty line, then exit 1) is exactly missing",
                     rc == 0 and so == "missing\n", f"rc={rc} out={so!r} err={se!r}"))
    rc, so, se, _ = run(f"service_state {gw}", gw)
    out.append(check("service_state: a running container is its state, running healthy",
                     rc == 0 and so == "running healthy\n", f"rc={rc} out={so!r} err={se!r}"))
    rc, so, se, calls = run("check_gateway", f"{gw} prometheus-ingest")
    out.append(check("service_state: check_gateway with prometheus-write-gateway running wants /ready 200 and passes",
                     rc == 0 and f"{gw}: /ready 200 with no account" in so
                     and calls == want, f"rc={rc} out={so!r} err={se!r} calls={calls}"))
    rc, so, se, calls = run("check_gateway", "")
    out.append(check("service_state: check_gateway with no gateway container checks nothing and passes",
                     rc == 0 and calls == [], f"rc={rc} out={so!r} err={se!r} calls={calls}"))
    return out


with tempfile.TemporaryDirectory() as d:
    sh = Path(d) / "observability.sh"
    sh.write_text(f'x=1\nOBSERVABILITY_TAG="${{OBSERVABILITY_TAG_OVERRIDE:-{TAG}}}"\n')
    tag_ok = dr.stack_tag(sh) == TAG
    sh.write_text('x=1\nOBSERVABILITY_TAG="${OBSERVABILITY_TAG_OVERRIDE:-latest}"\n')
    tag_latest = dr.stack_tag(sh) == "latest"
    sh.write_text('OBSERVABILITY_TAG="latest"\n')
    tag_bad = stops("tag: a line without the override form stops", "no OBSERVABILITY_TAG", lambda: dr.stack_tag(sh))
    sh.write_text('OBSERVABILITY_TAG="${OBSERVABILITY_TAG_OVERRIDE:-v1.2}"\n')
    tag_other = stops("tag: a tag that is neither latest nor a sha stops", "no OBSERVABILITY_TAG",
                      lambda: dr.stack_tag(sh))

results = [
    check("tag: a sha default (a pin) is read", tag_ok),
    check("tag: latest is read", tag_latest),
    tag_bad,
    tag_other,
    check("tag: this repo's observability.sh follows latest", dr.stack_tag(dr.HERE / "observability.sh") == "latest"),
    check("identities: plain kv= paths, one --identity each",
          dr.identity_args([("a", "A_T", ["r1", "r2"]), ("b", "B_T", ["r3"])])
          == ["--identity", "component=a,env=A_T,kv=secret/hubs/asyla/r1,kv=secret/hubs/asyla/r2",
              "--identity", "component=b,env=B_T,kv=secret/hubs/asyla/r3"]),
    check("identities: a secret/ record is a full path, passed through unchanged",
          dr.identity_args([("a", "A_T", ["r1", "secret/v2/x/y"])])
          == ["--identity", "component=a,env=A_T,kv=secret/hubs/asyla/r1,kv=secret/v2/x/y"]),
    stops("identities: one with no record stops (take its line out instead)", "no KV record",
          lambda: dr.identity_args([("a", "A_T", [])])),
    check("identities: the list is scrape-proxy, emporia-collector, alert-relay, loki-gateway, "
          "prometheus-write-gateway, pushgateway-gateway",
          [(c, e) for c, e, _ in dr.IDENTITIES] == list(zip(
              ["scrape-proxy", "emporia-collector", "alert-relay", "loki-gateway", "prometheus-write-gateway",
               "pushgateway-gateway"], OBS_TOKENS, strict=True))),
    *gateway_cases(),
    *gateways_cases(),
    check("identities: every record is a plain name or an own/ path under the hub's KV, or a full secret/ "
          "path, none with #",
          all(r and "#" not in r and ("/" not in r or r.startswith(("secret/", "own/")))
              and all(s and s not in (".", "..") for s in r.split("/"))
              for _, _, rs in dr.IDENTITIES for r in rs)),
    stops("spec: an identity whose variable build_host would not send stops", "start_env_optional lacks",
          lambda: dr.check_spec({**SPEC, "app": [{**SPEC["app"][0], "start_env_optional": OBS_TOKENS[:2]}]},
                                dr.IDENTITIES)),
    stops("spec: two identities with one variable stop", "each component once",
          lambda: dr.check_spec(SPEC, [("a", OBS_TOKENS[0], ["r"]), ("b", OBS_TOKENS[0], ["r"])])),
    d06_spec_case(),
    *relay_records_cases(),
    *alert_test_cases(),
    *data_dirs_cases(),
    *gateway_check_cases(),
    *service_state_cases(),
    check("start: --only apps, or late for an after_external app",
          dr.start_argv(SPEC)[4:6] == ["--only", "apps"]
          and dr.start_argv({**SPEC, "app": [{**SPEC["app"][0], "after_external": True}]})[4:6] == ["--only", "late"]),
    *pull_cases(),
    *verify_cases(),
    *run_start_cases(),
    *main_cases(),
    *given_token_cases(),
    *digests_cases(),
    *tool_cases(),
    *redirect_cases(),
    *registry_cases(),
]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
