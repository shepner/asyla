#!/usr/bin/env python3
"""Offline test of build_host.parse_args(): the parser accepts what the Usage block shows.

    python3 scripts/tests/test_build_host_args.py

`build_host.py HOST secrets push --apply VAR` (the documented order) was a usage error while
`--apply` before HOST worked. Tests the parser only: no action runs, and subprocess and urlopen
are replaced so that a call to a host or to GitLab would fail the test. Exit 0 when every case
passes.
"""
from __future__ import annotations

import contextlib
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the parser test reached out: {a[:1]}")


REAL_RUN = build_host.subprocess.run   # the wrapper cases run bash and git locally only
build_host.subprocess.run = _no_contact
build_host.urllib.request.urlopen = _no_contact

DEFAULTS = {"args": [], "apply": False, "start": None, "only": None, "recreate": False, "confirm": None,
            "node": None}


def parse(line: str) -> dict | str:
    """The parsed namespace as a dict, or 'exit N' when argparse refuses the line."""
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            return vars(build_host.parse_args(line.split()))
    except SystemExit as e:
        return f"exit {e.code}: {err.getvalue().strip().splitlines()[-1] if err.getvalue().strip() else ''}"


def same(name: str, want: dict, *lines: str) -> bool:
    """Every line parses to `want` (over the defaults): the orders are equivalent."""
    want = {**DEFAULTS, **want}
    ok = True
    for line in lines:
        got = parse(line)
        good = got == want
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'}  {name}: build_host.py {line}" + ("" if good else f"\n        got  {got}\n        want {want}"))
    return ok


def refused(name: str, line: str, needle: str) -> bool:
    got = parse(line)
    good = isinstance(got, str) and got.startswith("exit 2") and needle in got
    print(f"{'ok  ' if good else 'FAIL'}  {name}: build_host.py {line}" + ("" if good else f"\n        got  {got}"))
    return good


def spec_case(name: str, host: str, node: str | None, want: str, refused: bool = False) -> bool:
    """load_spec(host, node) from this checkout's specs. `want` is the node the spec ends up with,
    or with refused=True a piece of the Fail message. Reads files only."""
    try:
        got, failed = build_host.load_spec(host, node)["vm"]["node"], False
    except build_host.Fail as e:
        got, failed = str(e), True
    good = failed == refused and (want in got if refused else got == want)
    print(f"{'ok  ' if good else 'FAIL'}  {name}: load_spec({host!r}, {node!r}) -> {'Fail: ' if failed else ''}{got}")
    return good


def fails(name: str, needle: str, call) -> bool:
    """`call` raises build_host.Fail naming `needle`, without reaching a host or GitLab."""
    try:
        call()
        got = "no Fail"
    except build_host.Fail as e:
        got = str(e)
    good = needle in got
    print(f"{'ok  ' if good else 'FAIL'}  {name}: {got}")
    return good


def check(name: str, good: bool, detail: str = "") -> bool:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    return good


def temp_specs(specs: dict[str, str]):
    """load_spec() against throwaway specs: {host: host.toml text}. Returns a loader; files only."""
    import tempfile
    d = Path(tempfile.mkdtemp(prefix="build-host-spec-"))
    for host, text in specs.items():
        (d / host).mkdir()
        (d / host / "host.toml").write_text(text)

    def load(host: str) -> dict:
        real, build_host.REPO = build_host.REPO, d
        try:
            return build_host.load_spec(host)
        finally:
            build_host.REPO = real
    return load


VM = ('[vm]\nnode = "vmh01"\nvmid = 999\nsockets = 1\ncores = 1\nmemory_mb = 1024\nip = "10.0.0.250/24"\n'
      'os_disk = { storage = "local-data2", size = "8G" }\ncloudinit_storage = "local-data2"\n')
SECRET = '[[secret]]\nvar = "{var}"\npath = "/home/docker/{var}.env"\n'


APPS = '[[app]]\nname = "a"\n[[app]]\nname = "b"\n[[app]]\nname = "c"\n'
GITEA_APP = '[[app]]\nname = "gitea"\n[[app]]\nname = "b"\n'
REP_GITEA = '[replica]\nof = "d07"\napps = ["gitea"]\n'
GC = '[replica.gitea_config."cron.update_mirrors"]\nENABLED = false\n'
GL_RUNNER = ('[[gitlab_runner.runners]]\nname = "build"\nscope = "group:asyla"\ntags = ["t"]\nexecutor = "docker"\n'
             'image = "python:3.12-alpine"\n')


class Done:
    def __init__(self, rc: int, out: str = ""):
        self.returncode, self.stdout, self.stderr = rc, out, ""


def with_ssh(fake, call):
    """Run CALL with build_host.ssh replaced by FAKE(target, command) -> Done; returns (result, output)."""
    real, build_host.ssh = build_host.ssh, lambda t, c, **kw: fake(t, c)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            return call(), buf.getvalue()
    finally:
        build_host.ssh = real


def replica_guard_dry() -> bool:
    spec = temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + GC})("x")
    res, out = with_ssh(lambda t, c: (_ for _ in ()).throw(AssertionError("dry run reached " + t)),
                        lambda: build_host.replica_guard(spec, False))
    return check("replica guard, dry: names images, the egress block and gitea_config; reaches no host",
                 res is None and "replica_egress.sh" in out and "1 key(s)" in out, out)


def egress_case() -> bool:
    spec = temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA})("x")

    def fake(rcs):
        def f(t, c):
            for needle, rc in rcs:
                if needle in c:
                    return Done(rc)
            return Done(0)
        return f
    blocked = fake([("nft list", 0), ("curl -s -o /dev/null -m 5 https", 28), ("docker run", 28), ("docker exec", 6)])
    res, _ = with_ssh(blocked, lambda: build_host.egress_checks(spec, ["img:1"], ["gitea"]))
    good = len(res) == 5 and all(ok for _, ok, _ in res)
    open_host = fake([("nft list", 0), ("https://github.com", 0), ("curl -s", 28), ("docker run", 28)])
    res2, _ = with_ssh(open_host, lambda: build_host.egress_checks(spec, ["img:1"]))
    good2 = [ok for _, ok, _ in res2] == [True, True, False, True]   # table, gitlab, github, image
    no_tool = fake([("nft list", 0), ("docker run", 99), ("curl -s", 127)])   # the image probe holds "curl -s" too
    res3, _ = with_ssh(no_tool, lambda: build_host.egress_checks(spec, ["img:1"]))
    good3 = [ok for _, ok, _ in res3] == [True, False, False, False]
    no_table = fake([("nft list", 1), ("curl -s", 28)])
    res4, _ = with_ssh(no_table, lambda: build_host.egress_checks(spec))
    good4 = [ok for _, ok, _ in res4] == [False, True, True]
    return check("egress checks: blocked passes; a reachable URL, a missing curl or wget, or no table fails",
                 good and good2 and good3 and good4, str((res, res2, res3, res4)))


def ini_read_case() -> bool:
    spec = temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + GC
                       + '[replica.gitea_config.webhook]\nALLOWED_HOST_LIST = "w.invalid"\n'})("x")
    seen = []

    def fake(got):
        def f(t, c):
            seen.append(c)
            return Done(0, json.dumps(got) + "\n")
        return f
    (lines, bad), _ = with_ssh(fake({"cron.update_mirrors.ENABLED": "false", "webhook.ALLOWED_HOST_LIST": "w.invalid"}),
                               lambda: build_host.gitea_config_read(spec))
    (lines2, bad2), _ = with_ssh(fake({"cron.update_mirrors.ENABLED": "true", "webhook.ALLOWED_HOST_LIST": None}),
                                 lambda: build_host.gitea_config_read(spec))
    return check("gitea_config read back: the asked keys only; a wrong or missing value is a mismatch",
                 not bad and lines == ["[cron.update_mirrors] ENABLED = false", "[webhook] ALLOWED_HOST_LIST = w.invalid"]
                 and len(bad2) == 2 and build_host.GITEA_INI_HOST in seen[0] and "ENABLED" in seen[0],
                 str((lines, bad, lines2, bad2)))


def preflight(name: str, spec: dict, gitlab: dict, on_host: dict, up: set, want: str | None) -> bool:
    """preflight_secrets(spec, apply=True) with GitLab and the hosts replaced by dicts:
    gitlab {var: value}, on_host {(host, path): value}, up = the hosts that answer ssh.
    want: None when the build may go on, else a piece of the Fail message."""
    class R:
        def __init__(self, rc): self.returncode, self.stdout = rc, ""
    real = build_host.ssh, build_host.gitlab_secret, build_host.host_secret
    build_host.ssh = lambda target, command, **kw: R(0 if target in up else 255)
    build_host.gitlab_secret = gitlab.get
    build_host.host_secret = lambda host, path: on_host.get((host, path))
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            build_host.preflight_secrets(spec, True)
        got = None
    except build_host.Fail as e:
        got = str(e)
    finally:
        build_host.ssh, build_host.gitlab_secret, build_host.host_secret = real
    good = (got is None) if want is None else (got is not None and want in got)
    leaked = [v for v in list(gitlab.values()) + list(on_host.values()) if v and v in out.getvalue() + (got or "")]
    good = good and not leaked
    print(f"{'ok  ' if good else 'FAIL'}  pre-flight, {name}: {'goes on' if got is None else 'Fail: ' + got[:70]}"
          + (" (a VALUE was printed)" if leaked else ""))
    return good


def documented(name: str, text: str) -> bool:
    good = text in build_host.__doc__
    print(f"{'ok  ' if good else 'FAIL'}  {name}: {text!r} in the Usage block")
    return good


def spec_dir_case(name: str, host: str, setup_dir: bool, steps: list[str], build_steps: list[str],
                  needle: str | None) -> bool:
    """load_spec() on a throwaway repo with HOST/host.toml, maybe HOST/setup/, and build/setup/ files."""
    import tempfile
    d = Path(tempfile.mkdtemp(prefix="build-host-tree-"))
    (d / host).mkdir()
    (d / host / "host.toml").write_text(VM + f"[setup]\nsteps = {steps!r}\n".replace("'", '"'))
    if setup_dir:
        (d / host / "setup").mkdir()
        (d / host / "setup" / "old.sh").write_text("#!/bin/bash\n")
    (d / "build" / "setup").mkdir(parents=True)
    for s in build_steps:
        (d / "build" / "setup" / s).write_text("#!/bin/bash\n")
    real, build_host.REPO = build_host.REPO, d
    try:
        build_host.load_spec(host)
        got = None
    except build_host.Fail as e:
        got = str(e)
    finally:
        build_host.REPO = real
    good = got is None if needle is None else (got is not None and needle in got)
    print(f"{'ok  ' if good else 'FAIL'}  {name}{'' if good else f': {got!r}'}")
    return good


def wrapper_case(name: str, command: str, want_rc: int, want_in_listing: str) -> bool:
    """bundle_script() run by local bash on a hand-made bundle: COMMAND's exit status comes back,
    the bundle is unpacked where COMMAND runs, and the folder is gone afterwards."""
    import base64, io, tarfile, tempfile
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        data = b"#!/bin/bash\necho hi\n"
        info = tarfile.TarInfo("build/setup/x.sh"); info.size = len(data); info.mode = 0o755
        tf.addfile(info, io.BytesIO(data))
    base = Path(tempfile.mkdtemp(prefix="build-host-base-"))
    script = build_host.bundle_script(base64.b64encode(buf.getvalue()).decode(), command, str(base))
    r = REAL_RUN(["bash", "-c", script], capture_output=True, text=True, timeout=60)
    left = [p.name for p in base.iterdir()]
    good = r.returncode == want_rc and want_in_listing in r.stdout and not left
    print(f"{'ok  ' if good else 'FAIL'}  {name}" + ("" if good else f": rc {r.returncode}, out {r.stdout!r}, left {left}"))
    base.rmdir()
    return good


def bundle_case() -> bool:
    """bundle() of a path at HEAD (no fetch) decodes to a tar.gz holding that path."""
    import base64, io, tarfile
    real = build_host.subprocess.run
    build_host.subprocess.run = REAL_RUN
    try:
        names = tarfile.open(fileobj=io.BytesIO(base64.b64decode(build_host.bundle(["scripts/tests"], ref="HEAD")))).getnames()
    finally:
        build_host.subprocess.run = real
    good = "scripts/tests/test_build_host_args.py" in names
    print(f"{'ok  ' if good else 'FAIL'}  bundle of HEAD holds the asked path")
    return good


results = [
    # The secrets line, with --apply before and after the VAR names.
    documented("usage", "build_host.py HOST secrets check|push|install [--apply] [VAR ...]"),
    same("secrets push, one VAR, applied",
         {"host": "d03", "action": "secrets", "args": ["push", "VAR_A"], "apply": True},
         "d03 secrets push --apply VAR_A",          # the documented order (refused before the fix)
         "d03 secrets push VAR_A --apply",
         "--apply d03 secrets push VAR_A",
         "d03 --apply secrets push VAR_A",
         "d03 secrets --apply push VAR_A"),
    same("secrets push, two VARs, applied",
         {"host": "d03", "action": "secrets", "args": ["push", "VAR_A", "VAR_B"], "apply": True},
         "d03 secrets push --apply VAR_A VAR_B",
         "d03 secrets push VAR_A VAR_B --apply",
         "d03 secrets push VAR_A --apply VAR_B",
         "--apply d03 secrets push VAR_A VAR_B"),
    same("secrets push, no VAR, applied",
         {"host": "d03", "action": "secrets", "args": ["push"], "apply": True},
         "d03 secrets push --apply",
         "--apply d03 secrets push"),
    same("secrets install, one VAR, applied",
         {"host": "test01", "action": "secrets", "args": ["install", "VAR_A"], "apply": True},
         "test01 secrets install --apply VAR_A",
         "test01 secrets install VAR_A --apply"),
    # Without --apply nothing turns it on, whatever the VAR names are.
    same("secrets check, one VAR, dry",
         {"host": "d03", "action": "secrets", "args": ["check", "VAR_A"]},
         "d03 secrets check VAR_A"),
    same("secrets push, no VAR, dry",
         {"host": "d03", "action": "secrets", "args": ["push"]},
         "d03 secrets push"),
    # The other Usage lines still parse as before.
    same("plan", {"host": "test01", "action": "plan"}, "test01 plan"),
    same("verify", {"host": "test01", "action": "verify"}, "test01 verify"),
    same("scripts-check", {"host": "test01", "action": "scripts-check"}, "test01 scripts-check"),
    same("token", {"host": "test01", "action": "token", "apply": True}, "test01 token --apply", "--apply test01 token"),
    same("build, dry", {"host": "test01", "action": "build"}, "test01 build"),
    same("build --recreate --apply",
         {"host": "test01", "action": "build", "recreate": True, "apply": True},
         "test01 build --recreate --apply",
         "test01 build --apply --recreate",
         "--recreate --apply test01 build"),
    same("build --from", {"host": "test01", "action": "build", "apply": True, "start": "setup"},
         "test01 build --apply --from setup"),
    same("build --only", {"host": "test01", "action": "build", "only": "verify"}, "test01 build --only verify"),
    same("build --recreate --confirm",
         {"host": "d03", "action": "build", "recreate": True, "confirm": "d03"},
         "d03 build --recreate --confirm d03"),
    same("destroy", {"host": "test01", "action": "destroy", "apply": True, "confirm": "test01"},
         "test01 destroy --apply --confirm test01"),
    # Still refused: the intermixed parser must not start accepting stray words.
    refused("a stray word after build", "test01 build apply", "build takes no further arguments: apply"),
    refused("a stray word after an option", "test01 build --only verify extra", "build takes no further arguments: extra"),
    refused("a stray word after destroy", "test01 destroy --apply d03", "destroy takes no further arguments: d03"),
    refused("an unknown option", "d03 secrets push --aply VAR_A", "unrecognized arguments: --aply"),
    refused("an unknown action", "d03 secret push", "invalid choice"),
    refused("an unknown phase", "test01 build --only nothing", "invalid choice"),
    refused("no action", "test01", "required"),
    # secrets copy, and a VAR that is not in the spec (it used to match nothing and exit 0).
    documented("usage, secrets copy", "build_host.py HOST secrets copy [--apply] VAR FROM_VAR"),
    same("secrets copy, applied",
         {"host": "test01", "action": "secrets", "args": ["copy", "TEST01_HELLO_ENV", "D04_HELLO_ENV"], "apply": True},
         "test01 secrets copy --apply TEST01_HELLO_ENV D04_HELLO_ENV",
         "test01 secrets copy TEST01_HELLO_ENV D04_HELLO_ENV --apply"),
    fails("an unknown VAR is refused before any call", "not a [[secret]] of its spec: NOPE",
          lambda: build_host.secrets_cmd(build_host.load_spec("test01"), "check", False, ["NOPE"])),
    fails("secrets copy to a VAR outside the spec", "not a [[secret]] of its spec: D04_HELLO_ENV",
          lambda: build_host.secret_copy(build_host.load_spec("test01"), "D04_HELLO_ENV", "TEST01_HELLO_ENV", True)),
    # --node: the test host may be built on either node; a production host's node is its spec's.
    documented("usage, --node", "[--node NODE]"),
    same("build --node", {"host": "test01", "action": "build", "recreate": True, "apply": True, "node": "vmh02"},
         "test01 build --recreate --apply --node vmh02",
         "--node vmh02 test01 build --apply --recreate"),
    refused("an unknown node", "test01 build --node vmh09", "invalid choice"),
    spec_case("test01 defaults to its spec's node", "test01", None, "vmh01"),
    spec_case("test01 on the other node", "test01", "vmh02", "vmh02"),
    spec_case("a production host keeps its node", "d03", "vmh02", "is not disposable", refused=True),
    spec_case("a production host, its own node named", "d03", "vmh01", "vmh01"),
    # The test role is test01's alone: no other spec may be recreated or destroyed without --confirm.
    check("only test01 is disposable",
          sorted(p.parent.name for p in build_host.REPO.glob("*/host.toml")
                 if build_host.tomllib.loads(p.read_text()).get("vm", {}).get("disposable")) == ["test01"]),
    check("test01 is VMID 901 at 10.0.0.69", (lambda vm: (vm["vmid"], vm["ip"]) == (901, "10.0.0.69/24"))(
        build_host.load_spec("test01")["vm"])),
    check("d04 is on hold until its production spec exists", bool(build_host.load_spec("d04").get("hold"))),
    # Guests are reached as docker@HOST with the build's key; a node target is passed through.
    check("ssh to a guest names the user and the key",
          build_host.ssh_argv("test01")[-3:] == ["-i", str(build_host.SSH_KEY), "docker@test01"]),
    check("ssh to a node is unchanged", build_host.ssh_argv("root@vmh01")[-1] == "root@vmh01"
          and "-i" not in build_host.ssh_argv("root@vmh01")),
    # Start order: apps marked after_external start in the `late` phase, after the externals.
    documented("usage, the late phase", "late       the apps marked after_external = true"),
    check("late comes after external and before runner",
          build_host.PHASES.index("external") < build_host.PHASES.index("late") < build_host.PHASES.index("runner")),
    same("build --only late", {"host": "test01", "action": "build", "only": "late"}, "test01 build --only late"),
    check("apps: the unmarked apps, in spec order", [a["name"] for a in build_host.apps_in(
        {"app": [{"name": "a"}, {"name": "b", "after_external": True}, {"name": "c"}]}, False)] == ["a", "c"]),
    check("late: the marked apps only", [a["name"] for a in build_host.apps_in(
        {"app": [{"name": "a"}, {"name": "b", "after_external": True}, {"name": "c"}]}, True)] == ["b"]),
    check("no production spec marks an app late yet (each needs approval first)",
          not any(a.get("after_external") for h in ("d01", "d02", "d03") if (build_host.REPO / h / "host.toml").is_file()
                  for a in build_host.load_spec(h).get("app", []))),
    # [vm].startup: Proxmox's form only, since it goes into a qm command line.
    check("test01 has a start order", build_host.load_spec("test01")["vm"].get("startup") == "order=90"),
    check("startup with delays is accepted",
          temp_specs({"x": VM + 'startup = "order=15,up=30,down=60"\n'})("x")["vm"]["startup"] == "order=15,up=30,down=60"),
    fails("startup with a shell character is refused", "[vm].startup must be",
          lambda: temp_specs({"x": VM + 'startup = "order=1; reboot"\n'})("x")),
    fails("startup that is not a string is refused", "[vm].startup must be",
          lambda: temp_specs({"x": VM + 'startup = 15\n'})("x")),
    # The pre-flight: host files against GitLab before a build that may replace the host.
    check("secret states", [build_host.secret_state(g, h) for g, h in (("a", "a"), ("a", "b"), (None, "b"), ("a", None), (None, None))]
          == ["in sync", "DIFFERS", "MISSING in GitLab", "MISSING on host", "MISSING everywhere"]),
    check("pre-flight, dry: reaches no host and no GitLab",
          build_host.preflight_secrets(build_host.load_spec("d03"), False) is None),
    preflight("in sync", temp_specs({"x": VM + SECRET.format(var="A")})("x"),
              {"A": "s3cret-one"}, {("x", "/home/docker/A.env"): "s3cret-one"}, {"x"}, None),
    preflight("the host's file differs", temp_specs({"x": VM + SECRET.format(var="A")})("x"),
              {"A": "s3cret-one"}, {("x", "/home/docker/A.env"): "s3cret-two"}, {"x"}, "pre-flight: A:"),
    preflight("on the host only", temp_specs({"x": VM + SECRET.format(var="A")})("x"),
              {}, {("x", "/home/docker/A.env"): "s3cret-two"}, {"x"}, "pre-flight: A:"),
    preflight("in GitLab only (the build installs it)", temp_specs({"x": VM + SECRET.format(var="A")})("x"),
              {"A": "s3cret-one"}, {}, {"x"}, None),
    preflight("the host does not answer (a first build)", temp_specs({"x": VM + SECRET.format(var="A")})("x"),
              {"A": "s3cret-one"}, {}, set(), None),
    preflight("a replica: the source's files are read on the source",
              temp_specs({"d07": VM + SECRET.format(var="A"), "x": VM + '[replica]\nof = "d07"\n' + SECRET.format(var="B")})("x"),
              {"A": "s3cret-one", "B": "s3cret-b"}, {("d07", "/home/docker/A.env"): "s3cret-two"}, {"d07"}, "pre-flight: A:"),
    preflight("a replica whose source does not answer",
              temp_specs({"d07": VM + SECRET.format(var="A"), "x": VM + '[replica]\nof = "d07"\n'})("x"),
              {"A": "s3cret-one"}, {}, {"x"}, "d07 does not answer"),
    # Build files (one set in build/setup/; the legacy hosts keep HOST/setup/).
    check("the legacy hosts", build_host.LEGACY_HOSTS == ("d01", "d02", "d03")),
    spec_dir_case("a new host with its steps in build/setup/", "d09", False, ["a.sh"], ["a.sh"], None),
    spec_dir_case("a new host with a setup/ of its own is refused", "d09", True, ["a.sh"], ["a.sh"], "no build scripts of its own"),
    spec_dir_case("a step not in build/setup/ is refused", "d09", False, ["a.sh", "b.sh"], ["a.sh"], "not in build/setup/"),
    spec_dir_case("a legacy host keeps its setup/", "d02", True, ["a.sh"], [], None),
    check("test01's spec loads (its steps are in build/setup/)", build_host.load_spec("test01")["host"] == "test01"),
    check("test01's build-only paths", build_host.build_only_paths(build_host.load_spec("test01"))
          == [p for t in sorted({"test01", build_host.load_spec("test01")["apps_tree"]}) for p in (f"{t}/setup", f"{t}/host.toml")]
          + ["docker/setup"]),
    # A replica (gap G1): apps filter, its keys, no runner, gitea_config and verify, the egress guard.
    check("replica apps: only the named ones, in the source's order",
          [a["name"] for a in temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\napps = ["c", "a"]\n'})("x")["app"]]
          == ["a", "c"]),
    check("replica apps: all of the source's without the key",
          len(temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\n'})("x")["app"]) == 3),
    fails("replica apps: an unknown app is refused", "[replica].apps not in d07",
          lambda: temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\napps = ["zz"]\n'})("x")),
    fails("replica apps: an empty list is refused", "must be a list of app names",
          lambda: temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\napps = []\n'})("x")),
    fails("replica: an unknown key is refused", "unknown [replica] keys",
          lambda: temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\nstart = true\n'})("x")),
    fails("replica: a Gitea runner is refused (its egress is blocked)", "no [runner] or [gitlab_runner]",
          lambda: temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\n[runner]\nenabled = true\n'})("x")),
    fails("replica: a GitLab runner is refused", "no [runner] or [gitlab_runner]",
          lambda: temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\n' + GL_RUNNER})("x")),
    fails("replica: start_apps must be a boolean", "start_apps must be true or false",
          lambda: temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\nstart_apps = "no"\n'})("x")),
    check("replica gitea_config: accepted",
          temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + GC})("x")["replica"]["gitea_config"]["cron.update_mirrors"]
          == {"ENABLED": False}),
    fails("replica gitea_config: needs the gitea app", "needs the gitea app",
          lambda: temp_specs({"d07": VM + APPS, "x": VM + '[replica]\nof = "d07"\napps = ["a"]\n' + GC})("x")),
    fails("replica gitea_config: a lower-case key is refused", "must be upper-case",
          lambda: temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + '[replica.gitea_config.mirror]\nenabled = false\n'})("x")),
    fails("replica gitea_config: a section name with a space is refused", "lower-case app.ini section",
          lambda: temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + '[replica.gitea_config."a b"]\nX = 1\n'})("x")),
    fails("replica gitea_config: a value with a shell character is refused", "plain text",
          lambda: temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + '[replica.gitea_config.webhook]\nALLOWED_HOST_LIST = "a;b"\n'})("x")),
    fails("replica verify: a public URL is refused", "local URLs",
          lambda: temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + 'verify = ["https://gitea.example.org/"]\n'})("x")),
    fails("replica verify: another placeholder is refused", "local URLs",
          lambda: temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + 'verify = ["http://{ip}:3000/{x}"]\n'})("x")),
    check("environment-to-ini names: a dotted section is _0x2E_",
          build_host.gitea_env("cron.update_mirrors", "ENABLED") == "GITEA__cron_0x2E_update_mirrors__ENABLED"
          and build_host.gitea_env("webhook", "ALLOWED_HOST_LIST") == "GITEA__webhook__ALLOWED_HOST_LIST"),
    check("app.ini values: booleans as Gitea writes them",
          [build_host.ini_value(v) for v in (False, True, 3, "a.invalid")] == ["false", "true", "3", "a.invalid"]),
    check("test01 as the G1 replica: Gitea only, no secret, the outbound tasks off",
          not build_host.load_spec("test01").get("replica") or (
              [a["name"] for a in build_host.load_spec("test01")["app"]] == ["gitea"]
              and build_host.load_spec("test01")["secret"] == []
              and all(build_host.load_spec("test01")["replica"]["gitea_config"][s]["ENABLED"] is False
                      for s in ("cron.update_mirrors", "cron.update_checker", "cron.sync_external_users", "mirror"))
              and {build_host.load_spec("test01")["replica"]["gitea_config"][s]["ALLOWED_HOST_LIST"] for s in ("webhook", "security")}
              == {"webhook-delivery-disabled.invalid"})),
    replica_guard_dry(),
    egress_case(),
    ini_read_case(),
    wrapper_case("wrapper: the command runs in the unpacked bundle", 'ls -R "$B"', 0, "x.sh"),
    wrapper_case("wrapper: a failing command's status comes back and the folder is removed", 'bash "$B/build/setup/x.sh"; exit 3', 3, "hi"),
    bundle_case(),
]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
