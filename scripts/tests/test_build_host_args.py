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
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the parser test reached out: {a[:1]}")


REAL_RUN = build_host.subprocess.run   # the wrapper cases run bash and git locally only
build_host.subprocess.run = _no_contact
build_host.urllib.request.urlopen = _no_contact

DEFAULTS = {"args": [], "apply": False, "keys": False, "start": None, "only": None, "recreate": False, "confirm": None,
            "node": None, "gitea_host": None}


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
SPEC_FILE_ENTRY = '[[secret]]\nvar = "{var}"\npath = "/home/docker/{var}.env"\n'


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


def egress_no_shell_case() -> bool:
    """An image with no shell (vikunja's, exit 127) passes only beside another image that proves
    the default bridge; a running container with no shell is probed by the host's curl in its
    network namespace (nsenter), and a probe whose tooling fails (99) is no proof."""
    spec = temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA})("x")

    def fake(rcs):
        def f(t, c):
            for needle, rc in rcs:
                if needle in c:
                    return Done(rc)
            return Done(28)
        return f
    base = [("nft list", 0)]
    res, _ = with_ssh(fake(base + [("docker run --rm --entrypoint sh vik", 127), ("docker run", 28)]),
                      lambda: build_host.egress_checks(spec, ["vik:1", "py:1"]))
    good = [ok for _, ok, _ in res] == [True, True, True, True, True] and "proved by py:1" in res[-1][2]
    res2, _ = with_ssh(fake(base + [("docker run", 127)]), lambda: build_host.egress_checks(spec, ["vik:1"]))
    good2 = [ok for _, ok, _ in res2] == [True, True, True, False]
    seen = []

    def ns(rc):
        def f(t, c):
            seen.append(c)
            return Done(0 if "nft list" in c else 127 if "docker exec" in c else rc if "nsenter" in c else 28)
        return f
    res3, _ = with_ssh(ns(7), lambda: build_host.egress_checks(spec, containers=["ticketing-vikunja-1"]))
    good3 = res3[-1][1] and "network namespace" in res3[-1][0] and any("nsenter" in c for c in seen)
    res4, _ = with_ssh(ns(99), lambda: build_host.egress_checks(spec, containers=["ticketing-vikunja-1"]))
    res5, _ = with_ssh(ns(0), lambda: build_host.egress_checks(spec, containers=["ticketing-vikunja-1"]))
    return check("egress, no shell: an image passes beside a proving one, alone fails; a container goes "
                 "through nsenter, blocked passes, reached or no tooling fails",
                 good and good2 and good3 and not res4[-1][1] and not res5[-1][1], str((res, res2, res3, res4, res5)))


def replica_images_own_case() -> bool:
    """An app whose script has an `images` switch lists its own images (its env, login and replica
    overlay); one without keeps the bare compose listing."""
    spec = temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA})("x")
    calls = []

    def fake(has):
        def f(t, c):
            calls.append(c)
            if c.startswith("grep -qE"):
                return Done(0 if has else 1)
            return Done(0, "own:1\n" if c.endswith(" images") else "compose:1\n")
        return f
    own, _ = with_ssh(fake(True), lambda: build_host.replica_images(spec, True))
    own_cmd = [c for c in calls if c.endswith(" images")]
    calls.clear()
    bare, _ = with_ssh(fake(False), lambda: build_host.replica_images(spec, True))
    return check("replica images: the app's own `images` switch when it has one, else compose config",
                 own == ["own:1"] and own_cmd == ["~/scripts/d07/apps/gitea/gitea.sh images"]
                 and bare == ["compose:1"] and not any(c.endswith(" images") for c in calls), str((own, own_cmd, bare)))


ENV_APP = ('[[app]]\nname = "tk"\npull_token_env = "PULL_X"\nstart_env = ["START_A", "START_B"]\n')
ENV_NAMES = ["PULL_X", "START_A", "START_B"]


def app_env_cases() -> list[bool]:
    """[[app]] pull_token_env and start_env: validated names; values from build_host's environment go
    over SSH stdin only (never in the command), to images before restore, to the start commands, and
    start_env never on a replica."""
    out = [
        fails("app env: pull_token_env must be a variable name", "pull_token_env must be",
              lambda: temp_specs({"x": VM + '[[app]]\nname = "a"\npull_token_env = "a b"\n'})("x")),
        fails("app env: start_env must be a list of names", "start_env must be",
              lambda: temp_specs({"x": VM + '[[app]]\nname = "a"\nstart_env = "A"\n'})("x")),
        fails("app env: start_env names are distinct", "start_env must be",
              lambda: temp_specs({"x": VM + '[[app]]\nname = "a"\nstart_env = ["A", "A"]\n'})("x")),
        fails("app env: start_env cannot also carry the pull token's name", "which pull_token_env sets",
              lambda: temp_specs({"x": VM + '[[app]]\nname = "a"\npull_token_env = "P"\nstart_env = ["A_REGISTRY_PULL_TOKEN"]\n'})("x")),
        check("app env: the pull token's name on the host", build_host.pull_env_name("my-app") == "MY_APP_REGISTRY_PULL_TOKEN"),
    ]
    cmd, stdin = build_host.env_command([("VA", "one"), ("VB", "two words")], 'printf "%s|%s" "$VA" "$VB"')
    r = REAL_RUN(["bash", "-c", cmd], input=stdin, capture_output=True, text=True)   # locally only
    out.append(check("app env: env_command reads each value from stdin into its name; only names in the command",
                     r.stdout == "one|two words" and "one" not in cmd and "two" not in cmd and stdin == "one\ntwo words\n",
                     repr((cmd, r.stdout, r.stderr))))
    out.append(check("app env: nothing to send leaves the command alone", build_host.env_command([], "x up") == ("x up", None)))

    values = {n: f"stand-in-{i}" for i, n in enumerate(ENV_NAMES)}
    calls = []

    def fake(t, c, **kw):
        calls.append((c, kw.get("stdin")))
        return Done(0, "img:1\n")

    def run_with(env: dict, call):
        saved = {n: os.environ.pop(n) for n in ENV_NAMES if n in os.environ}
        os.environ.update(env)
        real_ssh, real_sec = build_host.ssh, build_host.secrets_cmd
        build_host.ssh, build_host.secrets_cmd = fake, (lambda *a, **kw: 0)
        calls.clear()
        try:
            with contextlib.redirect_stdout(io.StringIO()) as buf:
                try:
                    call()
                    got = ""
                except build_host.Fail as e:
                    got = str(e)
            return got, buf.getvalue()
        finally:
            build_host.ssh, build_host.secrets_cmd = real_ssh, real_sec
            for n in ENV_NAMES:
                os.environ.pop(n, None)
            os.environ.update(saved)

    prod = temp_specs({"x": VM + ENV_APP})("x")
    err, printed = run_with(values, lambda: build_host.phase_apps(prod, True))
    up = [(c, i) for c, i in calls if c.endswith("tk.sh up'")]
    out.append(check("app env: up gets the pull token and start_env over stdin, by name in the command only",
                     not err and len(up) == 1 and up[0][1] == "stand-in-0\nstand-in-1\nstand-in-2\n"
                     and "TK_REGISTRY_PULL_TOKEN START_A START_B" in up[0][0]
                     and not any(v in up[0][0] or v in printed for v in values.values()), repr((err, calls))))
    err, printed = run_with({"PULL_X": "stand-in-0", "START_A": "stand-in-1"}, lambda: build_host.phase_apps(prod, True))
    out.append(check("app env: an unset start_env name stops the start, naming it", "START_B is not in the environment" in err
                     and not calls and "stand-in" not in err + printed, err))
    err, printed = run_with(values, lambda: build_host.phase_restore(prod, True))
    order = [sw for c, _ in calls for sw in ("images", "restore") if f"tk.sh {sw}" in c]
    images = [i for c, i in calls if "tk.sh images" in c]
    out.append(check("app env: before its restore, `images` runs with the pull token alone over stdin",
                     not err and order == ["images", "restore"]
                     and images == ["stand-in-0\n"], repr((err, order, images))))
    rep_spec = temp_specs({"d07": VM + ENV_APP, "x": VM + '[replica]\nof = "d07"\n'})("x")
    err, printed = run_with({"PULL_X": "stand-in-0"}, lambda: build_host.phase_apps(rep_spec, True, late=True))
    calls.clear()
    real_guard = build_host.replica_guard
    build_host.replica_guard = lambda spec, apply: None
    try:
        err, printed = run_with({"PULL_X": "stand-in-0"}, lambda: build_host.phase_apps(rep_spec, True))
    finally:
        build_host.replica_guard = real_guard
    up = [(c, i) for c, i in calls if c.endswith("tk.sh up'")]
    out.append(check("app env: on a replica start_env is neither read nor sent; the pull token still is",
                     not err and len(up) == 1 and up[0][1] == "stand-in-0\n" and "START_A" not in up[0][0], repr((err, calls))))
    err, printed = run_with({}, lambda: build_host.replica_images(rep_spec, True))
    out.append(check("app env: a replica's image pull without the pull token fails, naming it",
                     "PULL_X is not in the environment" in err, err))
    return out


def egress_probe_case() -> bool:
    """EGRESS_PROBE_SH run here, on loopback only, with a PATH that holds python3 alone (d03's app
    images have no curl or wget, 2026-10-17) or nothing: a refused port is exit 1 (blocked), an
    HTTP 404 is an answer (exit 0, reached, as curl without -f), and no tool at all is 99."""
    import http.server
    import os
    import socket
    import tempfile
    import threading

    class NotFound(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_error(404)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), NotFound)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    closed = s.getsockname()[1]
    s.close()
    with tempfile.TemporaryDirectory() as only_py, tempfile.TemporaryDirectory() as empty:
        os.symlink(sys.executable, os.path.join(only_py, "python3"))

        def probe(bindir: str, url: str) -> int:
            return REAL_RUN(["/bin/sh", "-c", build_host.EGRESS_PROBE_SH, url], env={"PATH": bindir},
                            capture_output=True, timeout=30).returncode
        rcs = (probe(only_py, f"http://127.0.0.1:{closed}/"), probe(only_py, f"http://127.0.0.1:{srv.server_port}/"),
               probe(empty, "http://127.0.0.1:9/"))
    srv.shutdown()
    return check("egress probe with python3 only: refused is 1, an HTTP 404 is 0 (reached), no tool is 99",
                 rcs == (1, 0, 99), str(rcs))


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


def replica_verify_apps_case() -> bool:
    """verify's app lines for a replica: an app with start = [] (d03's ms-procedural-backup and
    ms-chronicle-backup run no container) is not checked as running (the 2026-10-17 d03 proof
    failed on it); a started app is, from the source's tree. restore = false: no restore line."""
    src = ('[[app]]\nname = "a"\nrestore = false\n[[app]]\nname = "b"\nstart = []\nrestore = false\nverify = ["verify"]\n')
    spec = temp_specs({"d07": VM + src, "x": VM + '[replica]\nof = "d07"\n'})("x")
    seen, lines = [], []

    def fake(t, c):
        seen.append(c)
        return Done(0, json.dumps([{"Status": "running(1)", "ConfigFiles": "/home/docker/scripts/d07/apps/a/compose.yml"}]))
    _, out = with_ssh(fake, lambda: build_host.verify_apps(spec, lambda label, ok, detail="": lines.append((label, ok))))
    return check("replica verify: a start = [] app is not checked as running; a started one is",
                 lines == [("app a running", True)] and len(seen) == 1 and "d07/apps/a" in seen[0]
                 and "app b: nothing started" in out, str((lines, seen, out)))


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


def keys_case() -> bool:
    """secrets check --keys with GitLab and the host replaced by dicts (harmless values): per key
    only its state, never a value; a non-dotenv or missing secret keeps its one line."""
    spec = {"host": "d09", "secret": [{"var": "V_ENV", "path": "/x/.env"}, {"var": "V_ENV2", "path": "/x/b.env"},
                                      {"var": "V_PEM", "path": "/x/k.pem"}, {"var": "V_GONE", "path": "/x/c.env"}]}
    gl = {"V_ENV": "# a comment\nA=valueone\nB=valuetwo\nC=valuethree\n",
          "V_ENV2": "A=valueone\nB=valuetwo\n", "V_PEM": "not a dotenv line\n"}
    host = {"/x/.env": "A=valueone\n\nB=valuechanged\nD=valuefour\n", "/x/b.env": "B=valuetwo\n# moved\nA=valueone\n",
            "/x/k.pem": "not a dotenv line either\n", "/x/c.env": "A=valueone\n"}
    real = build_host.gitlab_secret, build_host.host_secret
    build_host.gitlab_secret = gl.get
    build_host.host_secret = lambda h, path: host.get(path)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc = build_host.secrets_cmd(spec, "check", False, [], keys=True)
            plain = io.StringIO()
            with contextlib.redirect_stdout(plain):
                build_host.secrets_cmd(spec, "check", False, [])
    finally:
        build_host.gitlab_secret, build_host.host_secret = real
    text = out.getvalue()
    rows = [l.split() for l in text.splitlines() if l.startswith("    ")]
    leaked = [v for v in ("valueone", "valuetwo", "valuethree", "valuechanged", "valuefour", "dotenv", "either")
              if v in text]
    return check("secrets check --keys: per key its state only, no value; other secrets keep their line",
                 rc == 1 and not leaked
                 and rows == [["A", "same"], ["B", "DIFFERS"], ["C", "only", "in", "GitLab"], ["D", "only", "on", "host"],
                              ["A", "same"], ["B", "same"],
                              ["every", "key", "the", "same:", "the", "files", "differ", "only", "in", "comments,", "blank",
                               "lines,", "order", "or", "spacing"]]
                 and len([l for l in text.splitlines() if l.startswith("  V_")]) == 4
                 and "MISSING in GitLab" in text and "V_PEM" in text
                 and not any(l.startswith("    ") for l in plain.getvalue().splitlines()),
                 f"rc {rc}, leaked {leaked}\n{text}")


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
    documented("usage --keys", "build_host.py HOST secrets check --keys [VAR ...]"),
    same("secrets check --keys, one VAR",
         {"host": "d03", "action": "secrets", "args": ["check", "VAR_A"], "keys": True},
         "d03 secrets check --keys VAR_A",
         "d03 secrets check VAR_A --keys",
         "--keys d03 secrets check VAR_A"),
    refused("--keys with secrets push", "d03 secrets push --keys VAR_A", "--keys is for secrets check only"),
    refused("--keys with another action", "d03 plan --keys", "--keys is for secrets check only"),
    keys_case(),
    check("dotenv parse: comments, blanks, export; any other line is not dotenv",
          build_host.dotenv_keys("# c\n\nexport A=1\nB=two\n") == {"A": "1", "B": "two"}
          and build_host.dotenv_keys("A=1\nnot a line\n") is None and build_host.dotenv_keys("# only\n") is None
          and build_host.dotenv_keys(None) is None),
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
    check("d04's production spec: no hold, not disposable",
          (lambda d: not d.get("hold") and not d["vm"].get("disposable"))(build_host.load_spec("d04"))),
    check("d06's production spec: the operator's values (2026-10-18), not disposable, no docker label",
          (lambda d: (d["vm"]["node"], d["vm"]["vmid"], d["vm"]["ip"], d["vm"]["cores"], d["vm"]["memory_mb"],
                      d["vm"]["os_disk"], d["vm"]["data_disk"], bool(d["vm"].get("disposable")),
                      "docker" in d["runner"]["labels"])
           == ("vmh01", 106, "10.0.0.65/24", 8, 16384, {"storage": "local-data2", "size": "64G"},
               {"storage": "local-data2", "size": "64G"}, False, False))(build_host.load_spec("d06"))),
    check("d06 runs ticketing, verified by its own verify; its values come at use, none is a file on the host",
          (lambda d: [(a["name"], a.get("verify"), a.get("pull_token_env"), a.get("start_env")) for a in d["app"]]
           == [("ticketing", ["verify"], "THEORG_REGISTRY_PULL_TOKEN",
                ["TICKETING_DEPLOY_DEX_CLIENT_SECRET", "TICKETING_MCP_DEX_CLIENT_SECRET"])]
           and d.get("secret", []) == []
           and [(e["name"], e.get("env")) for e in d["external"]] == [("internal-access", ["D06_CF_API_TOKEN"])])(
               build_host.load_spec("d06"))),
    # Two specs never claim one VM or one address.
    check("every spec has its own VMID and address",
          (lambda vms: len({v["vmid"] for v in vms}) == len(vms) and len({v["ip"] for v in vms}) == len(vms))(
              [build_host.tomllib.loads(p.read_text())["vm"] for p in build_host.REPO.glob("*/host.toml")
               if "vm" in build_host.tomllib.loads(p.read_text())])),
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
    # [vm].vmid: a placeholder 0 (d03's spec before the operator chose 113) must never build.
    fails("vmid 0 (a placeholder) is refused", "[vm].vmid must be a whole number >= 100, not 0",
          lambda: temp_specs({"x": VM.replace("vmid = 999", "vmid = 0")})("x")),
    fails("vmid below 100 is refused", "[vm].vmid must be", lambda: temp_specs({"x": VM.replace("vmid = 999", "vmid = 99")})("x")),
    fails("vmid as a string is refused", "[vm].vmid must be",
          lambda: temp_specs({"x": VM.replace("vmid = 999", 'vmid = "113"')})("x")),
    fails("vmid as a boolean is refused", "[vm].vmid must be",
          lambda: temp_specs({"x": VM.replace("vmid = 999", "vmid = true")})("x")),
    check("vmid 100 is accepted", temp_specs({"x": VM.replace("vmid = 999", "vmid = 100")})("x")["vm"]["vmid"] == 100),
    check("d03 is VMID 113, never 103 (VM 103 is the way back)", build_host.load_spec("d03")["vm"]["vmid"] == 113),
    # The pre-flight: host files against GitLab before a build that may replace the host.
    check("secret states", [build_host.secret_state(g, h) for g, h in (("a", "a"), ("a", "b"), (None, "b"), ("a", None), (None, None))]
          == ["in sync", "DIFFERS", "MISSING in GitLab", "MISSING on host", "MISSING everywhere"]),
    check("pre-flight, dry: reaches no host and no GitLab",
          build_host.preflight_secrets(build_host.load_spec("d03"), False) is None),
    preflight("in sync", temp_specs({"x": VM + SPEC_FILE_ENTRY.format(var="A")})("x"),
              {"A": "s3cret-one"}, {("x", "/home/docker/A.env"): "s3cret-one"}, {"x"}, None),
    preflight("the host's file differs", temp_specs({"x": VM + SPEC_FILE_ENTRY.format(var="A")})("x"),
              {"A": "s3cret-one"}, {("x", "/home/docker/A.env"): "s3cret-two"}, {"x"}, "pre-flight: A:"),
    preflight("on the host only", temp_specs({"x": VM + SPEC_FILE_ENTRY.format(var="A")})("x"),
              {}, {("x", "/home/docker/A.env"): "s3cret-two"}, {"x"}, "pre-flight: A:"),
    preflight("in GitLab only (the build installs it)", temp_specs({"x": VM + SPEC_FILE_ENTRY.format(var="A")})("x"),
              {"A": "s3cret-one"}, {}, {"x"}, None),
    preflight("the host does not answer (a first build)", temp_specs({"x": VM + SPEC_FILE_ENTRY.format(var="A")})("x"),
              {"A": "s3cret-one"}, {}, set(), None),
    preflight("a replica: the source's files are read on the source",
              temp_specs({"d07": VM + SPEC_FILE_ENTRY.format(var="A"), "x": VM + '[replica]\nof = "d07"\n' + SPEC_FILE_ENTRY.format(var="B")})("x"),
              {"A": "s3cret-one", "B": "s3cret-b"}, {("d07", "/home/docker/A.env"): "s3cret-two"}, {"d07"}, "pre-flight: A:"),
    preflight("a replica whose source does not answer",
              temp_specs({"d07": VM + SPEC_FILE_ENTRY.format(var="A"), "x": VM + '[replica]\nof = "d07"\n'})("x"),
              {"A": "s3cret-one"}, {}, {"x"}, "d07 does not answer"),
    # Build files (one set in build/setup/; the legacy hosts keep HOST/setup/).
    check("the legacy hosts", build_host.LEGACY_HOSTS == ("d02",)),
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
    check("replica verify: a host-local 127.0.0.1 URL is accepted",
          temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + 'verify = ["http://127.0.0.1:3456/api/v1/info"]\n'})("x")
          ["replica"]["verify"] == ["http://127.0.0.1:3456/api/v1/info"]),
    fails("replica verify: another host's address is refused", "local URLs",
          lambda: temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + 'verify = ["http://10.0.0.9:3456/"]\n'})("x")),
    fails("replica verify: another placeholder is refused", "local URLs",
          lambda: temp_specs({"d07": VM + GITEA_APP, "x": VM + REP_GITEA + 'verify = ["http://{ip}:3000/{x}"]\n'})("x")),
    check("environment-to-ini names: a dotted section is _0x2E_",
          build_host.gitea_env("cron.update_mirrors", "ENABLED") == "GITEA__cron_0x2E_update_mirrors__ENABLED"
          and build_host.gitea_env("webhook", "ALLOWED_HOST_LIST") == "GITEA__webhook__ALLOWED_HOST_LIST"),
    check("app.ini values: booleans as Gitea writes them",
          [build_host.ini_value(v) for v in (False, True, 3, "a.invalid")] == ["false", "true", "3", "a.invalid"]),
    check("test01 as the G1 replica: Gitea only, no secret, the outbound tasks off",
          # only while test01 is the G1 (Gitea) replica: a replica of another host, such as a
          # d01 or d03 proof, has no gitea_config and is not this case
          not build_host.load_spec("test01").get("replica", {}).get("gitea_config") or (
              [a["name"] for a in build_host.load_spec("test01")["app"]] == ["gitea"]
              and build_host.load_spec("test01")["secret"] == []
              and all(build_host.load_spec("test01")["replica"]["gitea_config"][s]["ENABLED"] is False
                      for s in ("cron.update_mirrors", "cron.update_checker", "cron.sync_external_users", "mirror"))
              and {build_host.load_spec("test01")["replica"]["gitea_config"][s]["ALLOWED_HOST_LIST"] for s in ("webhook", "security")}
              == {"webhook-delivery-disabled.invalid"})),
    replica_guard_dry(),
    egress_case(),
    egress_no_shell_case(),
    replica_images_own_case(),
    *app_env_cases(),
    egress_probe_case(),
    ini_read_case(),
    replica_verify_apps_case(),
    wrapper_case("wrapper: the command runs in the unpacked bundle", 'ls -R "$B"', 0, "x.sh"),
    wrapper_case("wrapper: a failing command's status comes back and the folder is removed", 'bash "$B/build/setup/x.sh"; exit 3', 3, "hi"),
    bundle_case(),
]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
