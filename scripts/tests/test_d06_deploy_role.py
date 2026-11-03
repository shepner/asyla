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

    good = f"reg.example/theorg/observability-alert-relay:{TAG}\nprom/prometheus:v3\n"
    bh.ssh = fake(0, good)
    rc, printed = quiet(lambda: with_pull_env(lambda: dr.pull_images(SPEC, TAG)))
    out.append(check("images: the pull token goes over stdin only, by name in the command",
                     len(calls) == 1 and calls[0][2] == PULL + "\n" and PULL not in calls[0][1]
                     and "OBSERVABILITY_REGISTRY_PULL_TOKEN" in calls[0][1] and "observability.sh images" in calls[0][1]
                     and PULL not in printed, repr(calls)))
    bh.ssh = fake(0, "reg.example/theorg/observability-alert-relay:2144f83c\n")
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

    def fake_revision(spec, tag):
        seen.setdefault("order", []).append("revision")
        if seen.get("revision_stop"):
            raise dr.Stop(seen["revision_stop"])
        return REV

    real = (dr.unpack_tool, dr.pull_images, dr.hub_sign_in, dr.stack_tag, dr.has_tool, dr.build_host.load_spec,
            dr.run_start, dr.stack_revision)
    dr.unpack_tool = lambda rev, into: seen.setdefault("order", []).append(f"tool {rev}")
    dr.pull_images = lambda spec, tag: seen.setdefault("order", []).append("images")
    dr.stack_revision = fake_revision
    dr.hub_sign_in = lambda: HUB_STAND_IN
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
                         and f"2. d06: {SCRIPT} digests" in printed and "R on its origin/main" in printed
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
                         seen.get("order") == ["images", "revision", f"tool {REV}"], repr(seen.get("order"))))
        out.append(check("run: after a clean start, the app's verify runs on d06 with the revision; exit 0",
                         rc == 0 and seen.get("verify") == ("d06", f"OBSERVABILITY_REVISION={REV} {SCRIPT} verify")
                         and "verifies" in printed and REV in printed,
                         repr((rc, seen.get("verify"), printed))))
        seen.clear()
        seen.update(revision_stop="the theOrg images were built from different commits; nothing minted")
        rc, printed = quiet(lambda: with_pull_env(lambda: dr.main([])))
        out.append(check("run: a revision that cannot be read stops after the pull: no tool, no mint, no start, exit 1",
                         rc == 1 and seen.get("order") == ["images", "revision"] and "argv" not in seen
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
        os.environ.pop("THEORG_REGISTRY_PULL_TOKEN", None)
        rc, printed = quiet(lambda: dr.main([]))
        out.append(check("run: no pull token stops before anything runs", rc == 1 and not seen
                         and "THEORG_REGISTRY_PULL_TOKEN is not in the environment" in printed, printed))
    finally:
        (dr.unpack_tool, dr.pull_images, dr.hub_sign_in, dr.stack_tag, dr.has_tool, dr.build_host.load_spec,
         dr.run_start, dr.stack_revision) = real
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
    bh.ssh = fake(0, f"reg.example/theorg/observability-loki:latest {d1} {d2}\n"
                     f"reg.example/theorg/observability-vector:latest -\nprom/blackbox:v1 {d1}\n")
    got = dr.image_digests(SPEC)
    out.append(check("digests: `observability.sh digests` on d06, no stdin (no token); theOrg images only, - is none",
                     calls == [("d06", f"{SCRIPT} digests", None)]
                     and got == {"reg.example/theorg/observability-loki:latest": [d1, d2],
                                 "reg.example/theorg/observability-vector:latest": []}, repr((calls, got))))
    bh.ssh = fake(1, "")
    out.append(stops("digests: a failed read stops, nothing minted", "exit 1", lambda: quiet(lambda: dr.image_digests(SPEC))))
    bh.ssh = fake(0, f"prom/blackbox:v1 {d1}\n")
    out.append(stops("digests: no theOrg image stops", "listed no theOrg image", lambda: dr.image_digests(SPEC)))
    bh.ssh = _no_contact
    return out


def redirect_cases() -> list[bool]:
    """A redirect never carries the Authorization header off the registry's host, nor off https."""
    import urllib.request
    h = dr.AuthStaysRedirect()

    def follow(to):
        req = urllib.request.Request("https://reg.example/v2/r/blobs/x", headers={"Authorization": "Bearer stand-in-bearer"})
        return h.redirect_request(req, None, 307, "Temporary Redirect", {}, to)

    away, same = follow("https://storage.example/blob?sig=1"), follow("https://reg.example/v2/r/blobs/y")
    return [
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


REG = "reg.example"
BASIC = "Basic " + base64.b64encode(f"{dr.REGISTRY_USER}:{PULL}".encode()).decode()
BEARER = "stand-in-bearer"
SOURCE = "https://gitea.example/theOrg/observability"
NAMES = ("alert-relay", "alertmanager", "blackbox-exporter", "emporia-collector", "loki", "prometheus",
         "prometheus-trends", "pushgateway", "scrape-proxy", "vector")


def digest(*parts: str) -> str:
    import hashlib
    return "sha256:" + hashlib.sha256("/".join(parts).encode()).hexdigest()


class StandInRegistry:
    """A registry that answers http_get from what each image's provenance says: {name: [(source,
    revision), ...]} (one per attestation; [] for an index without one)."""

    def __init__(self, prov: dict, realm: str = f"https://{REG}/v2/token", scheme: str = "Bearer",
                 token_status: int = 200, predicate: str = "v1", index_body: bytes | None = None):
        self.prov, self.realm, self.scheme, self.token_status = prov, realm, scheme, token_status
        self.predicate, self.index_body, self.calls = predicate, index_body, []

    def digests_out(self, missing: str = "") -> str:
        return "".join(f"{REG}/theorg/observability-{n}:latest {'-' if n == missing else digest(n)}\n"
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
        if u.hostname != REG or headers.get("Authorization") != f"Bearer {BEARER}":
            return 401, {}, b""
        _, _, repo_kind = u.path.partition("/v2/")
        repo, kind, ref = repo_kind.rsplit("/", 2)
        n = repo.removeprefix("theorg/observability-")
        if kind == "manifests" and ref == digest(n):
            if self.index_body is not None:
                return 200, {}, self.index_body
            ms = [{"digest": digest(n, "amd64"), "platform": {"os": "linux", "architecture": "amd64"}}]
            ms += [{"digest": digest(n, "att", str(i)), "annotations": {
                "vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": digest(n, "amd64")}}
                for i in range(len(self.prov[n]))]
            return 200, {}, json.dumps({"manifests": ms}).encode()
        for i, (src, rev) in enumerate(self.prov.get(n, [])):
            if kind == "manifests" and ref == digest(n, "att", str(i)):
                return 200, {}, json.dumps({"layers": [
                    {"digest": digest(n, "blob", str(i)),
                     "annotations": {"in-toto.io/predicate-type": "https://slsa.dev/provenance/v1"}}]}).encode()
            if kind == "blobs" and ref == digest(n, "blob", str(i)):
                vcs = {"source": src, "revision": rev}
                pred = ({"runDetails": {"metadata": {"buildkit_metadata": {"vcs": vcs}}}} if self.predicate == "v1"
                        else {"metadata": {"https://mobyproject.org/buildkit@v1#metadata": {"vcs": vcs}}})
                return 200, {}, json.dumps({"predicate": pred}).encode()
        return 404, {}, b""


def registry_cases() -> list[bool]:
    out = []
    good = {n: [(SOURCE, REV)] for n in NAMES}

    def read(reg, tag="latest", missing=""):
        dr.http_get = reg
        bh.ssh = lambda target, cmd, **kw: Done(0, reg.digests_out(missing))
        try:
            return quiet(lambda: with_pull_env(lambda: dr.stack_revision(SPEC, tag)))
        finally:
            dr.http_get, bh.ssh = _no_contact, _no_contact

    def stopped(name, needle, reg, tag="latest", missing=""):
        return stops(name, needle, lambda: read(reg, tag, missing))

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
    out.append(check("registry: a pin that is the images' revision passes",
                     read(StandInRegistry(good), tag=REV[:7])[0] == REV))
    out.append(check("registry: buildkit's v0.2 provenance is read too",
                     read(StandInRegistry(good, predicate="v0.2"))[0] == REV))
    out.append(check("registry: the source as a .git URL, case aside, is theOrg's",
                     read(StandInRegistry({n: [(SOURCE.upper() + ".git", REV)] for n in NAMES}))[0] == REV))
    for name, needle, r, kw in (
            ("a token realm on another host is refused: the pull token is not sent", "no Bearer realm",
             StandInRegistry(good, realm="https://elsewhere.example/v2/token"), {}),
            ("a token realm over http is refused", "no Bearer realm",
             StandInRegistry(good, realm=f"http://{REG}/v2/token"), {}),
            ("a Basic challenge (no Bearer realm) is refused", "no Bearer realm",
             StandInRegistry(good, scheme="Basic"), {}),
            ("a refused pull token stops", "HTTP 401", StandInRegistry(good, token_status=401), {}),
            ("an image with no attestation stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": []}), {}),
            ("images built from different commits stop", "different commits",
             StandInRegistry({**good, "vector": [(SOURCE, "b" * 40)]}), {}),
            ("one image whose attestations disagree stops", "vector:latest: revisions",
             StandInRegistry({**good, "vector": [(SOURCE, REV), (SOURCE, "b" * 40)]}), {}),
            ("a source that is not theOrg's observability stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": [("https://gitea.example/grafana/loki", REV)]}), {}),
            ("a source whose path only ends in theorg/observability stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": [("https://elsewhere.example/x/theorg/observability", REV)]}), {}),
            ("a revision that is not 40 hex stops", "loki:latest: no theOrg revision",
             StandInRegistry({**good, "loki": [(SOURCE, "f599ebc5")]}), {}),
            ("a pin the provenance does not name stops", "as their build revision", StandInRegistry(good),
             {"tag": "b" * 40}),
            ("an image with no registry digest on d06 stops", "vector:latest: no registry digest", StandInRegistry(good),
             {"missing": "vector"}),
            ("an answer that is not understood stops", "not understood",
             StandInRegistry(good, index_body=b"<html>"), {})):
        r_calls = r.calls
        out.append(stopped(f"registry: {name}, nothing minted", needle, r, **kw))
        if "realm" in name or "Basic challenge" in name:
            out.append(check(f"registry: {name.split(':')[0]}: no request carried an Authorization header",
                             all("Authorization" not in h for _, h in r_calls)
                             and not any("elsewhere" in u for u, _ in r_calls), repr(r_calls)))
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
    *redirect_cases(),
    *registry_cases(),
]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
