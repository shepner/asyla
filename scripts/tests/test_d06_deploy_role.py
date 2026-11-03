#!/usr/bin/env python3
"""Offline test of d06/apps/observability/deploy_role.py: the plan it builds, and what each step
sends where. No SSH, no vault, no git, no registry: subprocess.run, build_host.ssh and http_get
are replaced so that any contact fails the test (run_start's own cases run a local python child,
nothing else; the registry cases answer from a stand-in registry in this file).

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
subprocess.run = _no_contact
bh.ssh = _no_contact
dr.http_get = _no_contact

TAG = "f7579118fdac5d90101a5ec6698200ae2c9d836f"
REV = "a" * 40   # a stand-in revision
OBS_TOKENS = ["SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN", "EMPORIA_OPENBAO_WRAPPED_TOKEN", "ALERT_RELAY_OPENBAO_WRAPPED_TOKEN"]
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
                         and argv[3:5] == ["--token-role", "observability-d06"] and argv.count("--identity") == 3
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
    out.append(check("tool: TOOL_REV is f757911, the commit asyla reviewed",
                     dr.TOOL_REV == "f7579118fdac5d90101a5ec6698200ae2c9d836f"))
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


def relay_records_cases() -> list[bool]:
    """alert-relay's token reads its SMTP login and the Watchdog's ping URL, each named in
    compose.yml; no delivery ping record (on only with the forge token), and the watchdog piece is on."""
    records = {c: rs for c, _, rs in dr.IDENTITIES}["alert-relay"]
    compose = (dr.HERE / "compose.yml").read_text()
    live = [ln.strip() for ln in compose.splitlines() if not ln.lstrip().startswith("#")]
    sh = (dr.HERE / "observability.sh").read_text()
    return [
        check("relay: its records are the SMTP login and the Watchdog's ping URL",
              records == ["smtp-relay-username", "smtp-relay-password", "observability-watchdog-ping-url"]),
        check("relay: compose.yml names each of its records",
              all(any(ln.startswith("ALERT_RELAY_") and f'"secret/hubs/asyla/{r}#value"' in ln for ln in live)
                  for r in records)),
        check("relay: no delivery ping record, in compose.yml or IDENTITIES",
              not any(ln.startswith("ALERT_RELAY_DELIVERY_PING_KV") for ln in live)
              and not any("delivery-ping" in r for _, _, rs in dr.IDENTITIES for r in rs)),
        check("relay: the watchdog piece is on in observability.sh",
              '\nALERT_WATCHDOG_PING="on"\n' in sh),
    ]


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
    stops("identities: one with no record stops (take its line out instead)", "no KV record",
          lambda: dr.identity_args([("a", "A_T", [])])),
    check("identities: the static list is scrape-proxy, emporia-collector, alert-relay",
          [(c, e) for c, e, _ in dr.IDENTITIES] == [("scrape-proxy", OBS_TOKENS[0]), ("emporia-collector", OBS_TOKENS[1]),
                                                    ("alert-relay", OBS_TOKENS[2])]),
    check("identities: every name and path is a plain path under the hub's KV",
          all(r and "#" not in r and "/" not in r for _, _, rs in dr.IDENTITIES for r in rs)),
    stops("spec: an identity whose variable build_host would not send stops", "start_env_optional lacks",
          lambda: dr.check_spec({**SPEC, "app": [{**SPEC["app"][0], "start_env_optional": OBS_TOKENS[:2]}]},
                                dr.IDENTITIES)),
    stops("spec: two identities with one variable stop", "each component once",
          lambda: dr.check_spec(SPEC, [("a", OBS_TOKENS[0], ["r"]), ("b", OBS_TOKENS[0], ["r"])])),
    d06_spec_case(),
    *relay_records_cases(),
    check("start: --only apps, or late for an after_external app",
          dr.start_argv(SPEC)[4:6] == ["--only", "apps"]
          and dr.start_argv({**SPEC, "app": [{**SPEC["app"][0], "after_external": True}]})[4:6] == ["--only", "late"]),
    *pull_cases(),
    *verify_cases(),
    *run_start_cases(),
    *main_cases(),
    *digests_cases(),
    *tool_cases(),
    *redirect_cases(),
    *registry_cases(),
]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
