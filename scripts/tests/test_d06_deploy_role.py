#!/usr/bin/env python3
"""Offline test of d06/apps/observability/deploy_role.py: the plan it builds, and what each step
sends where. No SSH, no vault, no git: subprocess.run and build_host.ssh are replaced so that any
contact fails the test (run_start's own cases run a local python child, nothing else).

    python3 scripts/tests/test_d06_deploy_role.py

Exit 0 when every case passes.
"""
from __future__ import annotations

import contextlib
import io
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


subprocess.run = _no_contact
bh.ssh = _no_contact

TAG = "75723657f825814038bf8936e4765a5137a073a8"
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

    good = f"reg.example/theorg/observability-loki-gateway:{TAG}\nprom/prometheus:v3\n"
    bh.ssh = fake(0, good)
    rc, printed = quiet(lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG)))
    out.append(check("images: the pull token goes over stdin only, by name in the command",
                     len(calls) == 1 and calls[0][2] == PULL + "\n" and PULL not in calls[0][1]
                     and "OBSERVABILITY_REGISTRY_PULL_TOKEN" in calls[0][1] and "observability.sh images" in calls[0][1]
                     and PULL not in printed, repr(calls)))
    bh.ssh = fake(0, "reg.example/theorg/observability-loki-gateway:2144f83c\n")
    out.append(stops("images: a theOrg image of another tag stops before any mint", "not of",
                     lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG))))
    out.append(stops("images: a stale scripts tree names the fix (merge, then install master with --only bootstrap)",
                     "build_host.py d06 build --only bootstrap --apply",
                     lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG))))
    bh.ssh = fake(0, "prom/prometheus:v3\n")
    out.append(stops("images: no theOrg image at all stops", "0 theOrg image(s)",
                     lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG))))
    bh.ssh = fake(1, "", f"login failed for {PULL}\n")
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        got = stops("images: a failed pull stops, nothing minted", "nothing minted",
                    lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG)))
    out.append(got)
    out.append(check("images: a failed pull's output is shown with the token redacted",
                     PULL not in buf.getvalue() and "login failed for ..." in buf.getvalue(), buf.getvalue()))
    # The value straddles the 2000-character cut: cut first, then redact, would leave its end.
    bh.ssh = fake(1, "", "a" * 100 + PULL + "b" * 1995)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stderr(buf):
            with_pull_env(lambda: dr.pull_images(SPEC, TAG))
    except dr.Stop:
        pass
    out.append(check("images: a failed pull's output is redacted before it is cut (no part of the token)",
                     PULL[-5:] not in buf.getvalue() and len(buf.getvalue().strip()) == 2000, repr(buf.getvalue()[:40])))

    def timeout(target, cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, kw.get("timeout"))
    bh.ssh = timeout
    out.append(stops("images: no answer in time is one clear line, nothing minted", "nothing minted",
                     lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG))))
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

    real = (dr.unpack_tool, dr.pull_images, dr.hub_sign_in, dr.stack_tag, dr.has_tool, dr.build_host.load_spec,
            dr.run_start)
    dr.unpack_tool = lambda tag, into: None
    dr.pull_images = lambda spec, tag: None
    dr.hub_sign_in = lambda: HUB_STAND_IN
    dr.stack_tag = lambda script: TAG
    dr.has_tool = lambda tag: True
    dr.build_host.load_spec = lambda host: SPEC
    dr.run_start = fake_start
    bh.ssh = fake_verify
    saved = {n: os.environ.get(n) for n in ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_ROOT_TOKEN", OBS_TOKENS[0],
                                            "THEORG_REGISTRY_PULL_TOKEN")}
    os.environ.update(dict.fromkeys((*OTHER_VAULT_VARS, OBS_TOKENS[0]), OTHER_STAND_IN))
    try:
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main(["--dry-run"])))
        out.append(check("dry run: prints the plan (with the verify step), runs nothing, exit 0",
                         rc == 0 and not seen and "DRY RUN" in printed and all(n in printed for n in OBS_TOKENS)
                         and f"5. d06: {SCRIPT} verify" in printed and "stand-in" not in printed, printed))
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
        out.append(check("run: after a clean start, the app's verify runs on d06; exit 0",
                         rc == 0 and seen.get("verify") == ("d06", f"{SCRIPT} verify") and "verifies" in printed,
                         repr((rc, seen.get("verify"), printed))))
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
        os.environ.pop("THEORG_REGISTRY_PULL_TOKEN", None)
        rc, printed = quiet(lambda: dr.main([]))
        out.append(check("run: no pull token stops before anything runs", rc == 1 and not seen
                         and "THEORG_REGISTRY_PULL_TOKEN is not in the environment" in printed, printed))
    finally:
        (dr.unpack_tool, dr.pull_images, dr.hub_sign_in, dr.stack_tag, dr.has_tool, dr.build_host.load_spec,
         dr.run_start) = real
        bh.ssh = _no_contact
        for n, v in saved.items():
            os.environ.pop(n, None)
            if v is not None:
                os.environ[n] = v
    return out


with tempfile.TemporaryDirectory() as d:
    sh = Path(d) / "observability.sh"
    sh.write_text(f'x=1\nOBSERVABILITY_TAG="${{OBSERVABILITY_TAG_OVERRIDE:-{TAG}}}"\n')
    tag_ok = dr.stack_tag(sh) == TAG
    sh.write_text('OBSERVABILITY_TAG="latest"\n')
    tag_bad = stops("tag: no sha pin stops", "no OBSERVABILITY_TAG", lambda: dr.stack_tag(sh))

results = [
    check("tag: the OBSERVABILITY_TAG default is the theOrg commit", tag_ok),
    tag_bad,
    check("tag: this repo's observability.sh pins one", len(dr.stack_tag(dr.HERE / "observability.sh")) >= 7),
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
    check("start: --only apps, or late for an after_external app",
          dr.start_argv(SPEC)[4:6] == ["--only", "apps"]
          and dr.start_argv({**SPEC, "app": [{**SPEC["app"][0], "after_external": True}]})[4:6] == ["--only", "late"]),
    *pull_cases(),
    *verify_cases(),
    *run_start_cases(),
    *main_cases(),
]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
