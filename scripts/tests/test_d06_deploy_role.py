#!/usr/bin/env python3
"""Offline test of d06/apps/observability/deploy_role.py: the plan it builds, and what each step
sends where. No SSH, no vault, no git: subprocess.run and build_host.ssh are replaced so that any
contact fails the test.

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
        "app": [{"name": "observability", "pull_token_env": "THEORG_REGISTRY_PULL_TOKEN",
                 "start_env_optional": list(OBS_TOKENS)}]}


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
    bh.ssh = _no_contact
    return out


def main_cases() -> list[bool]:
    out = []
    seen = {}

    def fake_run(argv, env=None, **kw):
        seen["argv"], seen["env"] = argv, env
        return Done(seen.get("rc", 0))

    real = (dr.unpack_tool, dr.pull_images, dr.hub_sign_in, dr.stack_tag, dr.has_tool, dr.build_host.load_spec)
    dr.unpack_tool = lambda tag, into: None
    dr.pull_images = lambda spec, tag: None
    dr.hub_sign_in = lambda: HUB_STAND_IN
    dr.stack_tag = lambda script: TAG
    dr.has_tool = lambda tag: True
    dr.build_host.load_spec = lambda host: SPEC
    dr.subprocess.run = fake_run
    saved = {n: os.environ.get(n) for n in ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_ROOT_TOKEN", OBS_TOKENS[0],
                                            "THEORG_REGISTRY_PULL_TOKEN")}
    os.environ.update(dict.fromkeys((*OTHER_VAULT_VARS, OBS_TOKENS[0]), OTHER_STAND_IN))
    try:
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main(["--dry-run"])))
        out.append(check("dry run: prints the plan, runs nothing, exit 0",
                         rc == 0 and not seen and "DRY RUN" in printed and all(n in printed for n in OBS_TOKENS)
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
        seen.clear()
        seen["rc"] = 1
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("run: a mint failure exits non-zero", rc == 1, printed))
        seen.clear()
        os.environ.pop("THEORG_REGISTRY_PULL_TOKEN", None)
        rc, printed = quiet(lambda: dr.main([]))
        out.append(check("run: no pull token stops before anything runs", rc == 1 and not seen
                         and "THEORG_REGISTRY_PULL_TOKEN is not in the environment" in printed, printed))
    finally:
        (dr.unpack_tool, dr.pull_images, dr.hub_sign_in, dr.stack_tag, dr.has_tool, dr.build_host.load_spec) = real
        dr.subprocess.run = _no_contact
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
          lambda: dr.check_spec({**SPEC, "app": [{"name": "observability", "start_env_optional": OBS_TOKENS[:2]}]},
                                dr.IDENTITIES)),
    stops("spec: two identities with one variable stop", "each component once",
          lambda: dr.check_spec(SPEC, [("a", OBS_TOKENS[0], ["r"]), ("b", OBS_TOKENS[0], ["r"])])),
    d06_spec_case(),
    check("start: --only apps, or late for an after_external app",
          dr.start_argv(SPEC)[4:6] == ["--only", "apps"]
          and dr.start_argv({**SPEC, "app": [{**SPEC["app"][0], "after_external": True}]})[4:6] == ["--only", "late"]),
    *pull_cases(),
    *main_cases(),
]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
