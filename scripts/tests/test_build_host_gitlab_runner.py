#!/usr/bin/env python3
"""Offline test of the GitLab runners of a host spec (gap G9): [gitlab_runner] in load_spec(),
the API calls of the runner phase, destroy and verify (GitLab and the host replaced by fakes), and
build/gitlab-runner/gitlab-runner.sh's register and finish run by local bash against a throwaway
config file and a fake gitlab-runner.

    python3 scripts/tests/test_build_host_gitlab_runner.py

Nothing reaches GitLab or a host: subprocess and urlopen are replaced so that a stray call fails
the test. The runner token of the fakes is built from parts and is no token. Exit 0 when every
case passes.
"""
from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the test reached out: {a[:1]}")


REAL_RUN = build_host.subprocess.run   # the host-script cases run local bash only
build_host.subprocess.run = _no_contact
build_host.urllib.request.urlopen = _no_contact
build_host.time.sleep = lambda s: None

FAKE_TOKEN = "-".join(["fake", "runner", "auth", "value"])   # a placeholder, built from parts
results: list[bool] = []


def check(name: str, good: bool, detail: str = "") -> None:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    results.append(good)


VM = ('[vm]\nnode = "vmh01"\nvmid = 999\nsockets = 1\ncores = 1\nmemory_mb = 1024\nip = "10.0.0.250/24"\n'
      'os_disk = { storage = "local-data2", size = "8G" }\ncloudinit_storage = "local-data2"\n')
RUNNER = ('[[gitlab_runner.runners]]\nname = "{name}"\nscope = "{scope}"\ntags = {tags}\nexecutor = "docker"\n'
          'image = "python:3.12-alpine"\n')


def load(text: str, host: str = "d09") -> dict:
    d = Path(tempfile.mkdtemp(prefix="build-host-glr-"))
    (d / host).mkdir()
    (d / host / "host.toml").write_text(VM + text)
    real, build_host.REPO = build_host.REPO, d
    try:
        return build_host.load_spec(host)
    finally:
        build_host.REPO = real


def test01_spec() -> dict:
    """test01's spec. While test01 rehearses a production host ([replica], e.g. gap G1), the hello
    spec as committed at 226904e instead, so these cases keep a spec with the tables they test."""
    t = build_host.load_spec("test01")
    if not t.get("replica"):
        return t
    text = REAL_RUN(["git", "-C", str(build_host.REPO), "show", "226904e:test01/host.toml"],
                    capture_output=True, text=True, check=True).stdout
    d = Path(tempfile.mkdtemp(prefix="build-host-test01-"))
    (d / "test01").mkdir()
    (d / "test01" / "host.toml").write_text(text)
    (d / "build").symlink_to(build_host.REPO / "build")
    real, build_host.REPO = build_host.REPO, d
    try:
        return build_host.load_spec("test01")
    finally:
        build_host.REPO = real


def spec_ok(name: str, text: str) -> dict | None:
    try:
        s = load(text)
        check(f"spec accepted: {name}", True)
        return s
    except build_host.Fail as e:
        check(f"spec accepted: {name}", False, str(e))
        return None


def spec_refused(name: str, text: str, needle: str) -> None:
    try:
        load(text)
        got = "accepted"
    except build_host.Fail as e:
        got = str(e)
    check(f"spec refused: {name}", needle in got, got)


# ---------------------------------------------------------------- the spec

one = RUNNER.format(name="build", scope="group:asyla", tags='["build-test"]')
s = spec_ok("one group runner", one)
check("its description is HOST-NAME", s is not None and build_host.gitlab_runners(s)[0]["description"] == "d09-build")
check("no [gitlab_runner]: no runners", build_host.gitlab_runners(load("")) == [])
spec_ok("a project runner with volumes and a pull policy",
        RUNNER.format(name="maint", scope="project:asyla/host-maintenance", tags='["d09", "maint"]')
        + 'volumes = ["/home/docker/.config/x:/x:ro"]\npull_policy = "always"\n')
spec_ok("a shell runner", '[[gitlab_runner.runners]]\nname = "sh"\nscope = "group:asyla"\ntags = ["t"]\nexecutor = "shell"\n')
spec_refused("a name with a space", RUNNER.format(name="a b", scope="group:asyla", tags='["t"]'), "runner name must be")
spec_refused("two runners with one name", one + one, "named twice")
spec_refused("a scope without a kind", RUNNER.format(name="a", scope="asyla", tags='["t"]'), "scope must be")
spec_refused("a scope of another kind", RUNNER.format(name="a", scope="instance:x", tags='["t"]'), "scope must be")
spec_refused("a scope with a shell character", RUNNER.format(name="a", scope="group:a;b", tags='["t"]'), "scope must be")
spec_refused("no tags (it would take untagged jobs)", RUNNER.format(name="a", scope="group:asyla", tags="[]"), "tags must be")
spec_refused("a tag with a comma", RUNNER.format(name="a", scope="group:asyla", tags='["a,b"]'), "tags must be")
spec_refused("an unknown executor", RUNNER.format(name="a", scope="group:asyla", tags='["t"]').replace('"docker"', '"kubernetes"'),
             "executor must be")
spec_refused("a docker runner without an image",
             RUNNER.format(name="a", scope="group:asyla", tags='["t"]').replace('image = "python:3.12-alpine"\n', ""),
             "needs image")
spec_refused("a bad pull policy", one + 'pull_policy = "sometimes"\n', "pull_policy must be")
spec_refused("a volume with a space", one + 'volumes = ["/a b:/c"]\n', "volumes must be")
spec_refused("an unknown key", one + 'run_untagged = true\n', "unknown keys")
spec_refused("an image on a shell runner",
             '[[gitlab_runner.runners]]\nname = "sh"\nscope = "group:asyla"\ntags = ["t"]\nexecutor = "shell"\nimage = "x"\n',
             "unknown keys")
spec_refused("another key in the table", '[gitlab_runner]\nconcurrent = 2\n' + one, "only runners")
t = test01_spec()
check("test01: one group runner on asyla, tag build-test only",
      [(r["description"], r["scope"], r["tags"]) for r in build_host.gitlab_runners(t)]
      == [("test01-build", "group:asyla", ["build-test"])])
check("no legacy or production spec has a GitLab runner yet (each needs approval first)",
      not any(build_host.gitlab_runners(build_host.load_spec(h)) for h in ("d01", "d02", "d03")
              if (build_host.REPO / h / "host.toml").is_file()))
check("register options: docker as on d03, one job at a time",
      build_host.gl_register_args(build_host.gitlab_runners(t)[0])
      == ["--url", "https://gitlab.com", "--executor", "docker", "--limit", "1",
          "--docker-image", "python:3.12-alpine", "--docker-pull-policy", "if-not-present"])
check("scopes map to type-filtered API paths",
      [build_host.gl_scope(x) for x in ("group:asyla", "project:asyla/host-maintenance")]
      == [("group", "/groups/asyla"), ("project", "/projects/asyla%2Fhost-maintenance")])


# ---------------------------------------------------------------- the API, faked

class FakeGitLab:
    """GitLab's runner API as the build uses it. Runners: id -> dict(description, scope, status,
    tag_list, run_untagged). Records every call."""

    def __init__(self, runners: dict[int, dict]):
        self.runners, self.calls, self.next_id = runners, [], 900

    def __call__(self, method: str, path: str, body: dict | None = None):
        self.calls.append((method, path, body))
        if method == "GET" and path in ("/groups/asyla", "/projects/asyla%2Fhost-maintenance"):
            return 200, {"id": 11 if path.startswith("/groups") else 22}
        for scope, base in (("group:asyla", "/groups/asyla"), ("project:asyla/host-maintenance",
                                                               "/projects/asyla%2Fhost-maintenance")):
            if method == "GET" and path.startswith(base + "/runners"):
                kind = scope.split(":")[0]
                if f"type={kind}_type" not in path:
                    return 400, {"error": "the test wants a type filter"}
                return 200, [{"id": i, "description": r["description"], "status": r["status"]}
                             for i, r in self.runners.items() if r["scope"] == scope]
        if method == "GET" and path.startswith("/runners/"):
            r = self.runners.get(int(path.split("/")[2]))
            return (200, {"id": int(path.split("/")[2]), **r}) if r else (404, {})
        if method == "DELETE" and path.startswith("/runners/"):
            return (204, {}) if self.runners.pop(int(path.split("/")[2]), None) else (404, {})
        if method == "POST" and path == "/user/runners":
            self.next_id += 1
            scope = "group:asyla" if body["runner_type"] == "group_type" else "project:asyla/host-maintenance"
            self.runners[self.next_id] = {"description": body["description"], "scope": scope, "status": "never_contacted",
                                          "tag_list": body["tag_list"].split(","), "run_untagged": body["run_untagged"]}
            return 201, {"id": self.next_id, "token": FAKE_TOKEN, "token_expires_at": None}
        return 404, {}


def others() -> dict[int, dict]:
    """The production runners that must never be touched, plus one with a look-alike description."""
    return {53360564: {"description": "d03 group", "scope": "group:asyla", "status": "online",
                       "tag_list": ["d03"], "run_untagged": False},
            56843179: {"description": "host-maintenance-d03", "scope": "project:asyla/host-maintenance",
                       "status": "online", "tag_list": ["maint"], "run_untagged": False},
            70: {"description": "test01-build-old", "scope": "group:asyla", "status": "online",
                 "tag_list": ["x"], "run_untagged": False}}


def with_fakes(gl: FakeGitLab, fn, ssh_out: str = ""):
    """Run fn() with GitLab, build_run and ssh replaced; returns (result or Fail text, build_run calls, output)."""
    runs = []

    class R:
        returncode, stdout, stderr = 0, ssh_out, ""

    real = build_host.gitlab, build_host.build_run, build_host.ssh

    def fake_build_run(host, paths, command, as_root, stdin=None):
        runs.append((host, paths, command, as_root, stdin))
        if " register " in f" {command} ":    # the host contacts GitLab once registered
            for r in gl.runners.values():
                if r["status"] == "never_contacted":
                    r["status"] = "online"

    build_host.gitlab, build_host.build_run = gl, fake_build_run
    build_host.ssh = lambda target, command, **kw: R()
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            res = fn()
    except build_host.Fail as e:
        res = f"Fail: {e}"
    finally:
        build_host.gitlab, build_host.build_run, build_host.ssh = real
    return res, runs, out.getvalue()


# Dry run: lists the stale entry, deletes nothing, creates nothing, reaches no host.
stale = {**others(), 80: {"description": "test01-build", "scope": "group:asyla", "status": "offline",
                          "tag_list": ["build-test"], "run_untagged": False}}
gl = FakeGitLab(dict(stale))
res, runs, out = with_fakes(gl, lambda: build_host.phase_gitlab_runner(t, False))
check("dry run: names the stale entry, changes nothing, reaches no host",
      "delete GitLab runner test01-build (id 80" in out and not runs
      and all(m == "GET" for m, _, _ in gl.calls) and set(gl.runners) == set(stale), out)

# Apply: the stale entry goes, a new one is made and registered with the token on stdin only.
gl = FakeGitLab(dict(stale))
res, runs, out = with_fakes(gl, lambda: build_host.phase_gitlab_runner(t, True))
posts = [b for m, p, b in gl.calls if m == "POST"]
deletes = [p for m, p, _ in gl.calls if m == "DELETE"]
check("apply: completes", res is None, str(res))
check("apply: only the stale entry with the same description is deleted", deletes == ["/runners/80"], str(deletes))
check("apply: the production runners and a look-alike are untouched",
      all(i in gl.runners for i in (53360564, 56843179, 70)))
check("apply: POST /user/runners as a group runner, tag build-test, untagged off",
      posts == [{"runner_type": "group_type", "group_id": 11, "description": "test01-build",
                 "tag_list": "build-test", "run_untagged": False}], str(posts))
check("apply: every listing is type-filtered",
      all("?type=" in p for m, p, _ in gl.calls if m == "GET" and "/runners?" in p)
      and any("/runners?" in p for _, p, _ in gl.calls))
check("apply: install, register, finish on the host, as root, from build/gitlab-runner only",
      [c.split('gitlab-runner.sh" ')[1].split()[0] for _, _, c, _, _ in runs] == ["install", "register", "finish"]
      and all(r[3] and r[1] == ["build/gitlab-runner"] and r[0] == "test01" for r in runs), str(runs))
reg = runs[1]
check("apply: the token goes on stdin, never in the command", reg[4] == FAKE_TOKEN + "\n" and FAKE_TOKEN not in reg[2]
      and all(FAKE_TOKEN not in r[2] for r in runs) and not any(r[4] for r in runs if r is not reg))
check("apply: register names the runner by its description",
      "register test01-build --url https://gitlab.com --executor docker" in reg[2], reg[2])
check("apply: finish keeps the spec's runners", runs[2][2].endswith("finish test01-build"), runs[2][2])
check("apply: the token is never printed", FAKE_TOKEN not in out)
check("apply: waits until the new runner is online", "GitLab runners online: test01-build" in out, out)

# A runner that never comes online fails the phase.
gl = FakeGitLab(others())
real_wait = build_host.GL_ONLINE_WAIT
build_host.GL_ONLINE_WAIT = -1


def no_contact_run():
    def fake(host, paths, command, as_root, stdin=None):
        pass
    build_host.build_run = fake
    return build_host.phase_gitlab_runner(t, True)


res, _, _ = with_fakes(gl, no_contact_run)
build_host.GL_ONLINE_WAIT = real_wait
check("a runner that never comes online fails the phase", isinstance(res, str) and "not online" in res, str(res))

# A failed create stops before the host sees anything, and the body is not printed.

class Refusing(FakeGitLab):
    def __call__(self, method, path, body=None):
        if method == "POST":
            self.calls.append((method, path, body))
            return 403, {"message": "insufficient_scope"}
        return super().__call__(method, path, body)


gl = Refusing(others())
res, runs, out = with_fakes(gl, lambda: build_host.phase_gitlab_runner(t, True))
check("a refused create fails with its HTTP status",
      isinstance(res, str) and "create GitLab runner test01-build in group:asyla: HTTP 403" in res, str(res))
check("a refused create registers nothing", [c for _, _, c, _, _ in runs if "register" in c] == [])

# Destroy deletes the host's runners (and only those).
gl = FakeGitLab(dict(stale))
res, _, out = with_fakes(gl, lambda: build_host.delete_gitlab_runner_entries(t, True))
check("destroy: the host's runner entry is deleted, the others stay",
      80 not in gl.runners and all(i in gl.runners for i in (53360564, 56843179, 70)))

# Verify: online, tags and run_untagged from GitLab; names and concurrent from the host.
good_host = 'active\nconcurrent = 1\n  name = "test01-build"\n'


def verify_lines(runners: dict[int, dict], host_out: str = good_host) -> list[str]:
    """verify_gitlab_runners(test01) against the fakes: its check lines."""
    lines: list[str] = []
    gl = FakeGitLab(runners)
    with_fakes(gl, lambda: build_host.verify_gitlab_runners(
        t, lambda label, ok, detail="": lines.append(f"[{'OK' if ok else 'FAIL'}] {label}: {detail}")), host_out)
    return lines


def fails_on(lines: list[str], needle: str) -> bool:
    return any(l.startswith("[FAIL]") and needle in l for l in lines)


ok_runner = {81: {"description": "test01-build", "scope": "group:asyla", "status": "online",
                  "tag_list": ["build-test"], "run_untagged": False}}
lines = verify_lines({**others(), **ok_runner})
check("verify: online with the spec's tags, host config right: three OK lines",
      len(lines) == 3 and all(l.startswith("[OK]") for l in lines), str(lines))
check("verify: an extra tag fails",
      fails_on(verify_lines({**others(), 81: {**ok_runner[81], "tag_list": ["build-test", "d03"]}}), "tags are the spec's"))
check("verify: untagged jobs on fails",
      fails_on(verify_lines({**others(), 81: {**ok_runner[81], "run_untagged": True}}), "untagged jobs off"))
check("verify: offline fails", fails_on(verify_lines({**others(), 81: {**ok_runner[81], "status": "offline"}}), "online"))
check("verify: no entry fails", fails_on(verify_lines(others()), "no entry"))
check("verify: two entries fail", fails_on(verify_lines({**others(), **ok_runner, 82: dict(ok_runner[81])}), "online"))
check("verify: a stale local entry fails",
      fails_on(verify_lines({**others(), **ok_runner}, good_host + '  name = "test01-old"\n'), "spec's runners only"))
check("verify: concurrent other than the number of runners fails",
      fails_on(verify_lines({**others(), **ok_runner}, good_host.replace("concurrent = 1", "concurrent = 4")), "concurrent"))
check("verify: the unit not active fails",
      fails_on(verify_lines({**others(), **ok_runner}, good_host.replace("active", "inactive")), "gitlab-runner active"))
check("verify: no spec runner, no line", verify_lines(others()) and not [
    l for l in (lambda: (lambda lines: (with_fakes(FakeGitLab(others()), lambda: build_host.verify_gitlab_runners(
        load(""), lambda *a: lines.append(a))), lines)[1])([]))()])


# ---------------------------------------------------------------- the host script, local bash

SCRIPT = build_host.REPO / build_host.BUILD_GITLAB_RUNNER / "gitlab-runner.sh"
CONFIG = """concurrent = 1
check_interval = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "test01-build"
  url = "https://gitlab.com"
  url = "https://old-entry.example/"
  executor = "docker"
  [runners.docker]
    image = "python:3.12-alpine"

[[runners]]
  name = "test01-gone"
  url = "https://gitlab.com"
  executor = "docker"
"""


def host_script(args: list[str], stdin: str, fake_rc: int = 0, fake_says: str = "") -> tuple[int, str, str, Path]:
    """gitlab-runner.sh ARGS with a fake gitlab-runner on PATH that records its argv and whether
    CI_SERVER_TOKEN was set (and to what), then appends a runner block like the real one."""
    d = Path(tempfile.mkdtemp(prefix="glr-script-"))
    (d / "bin").mkdir()
    fake = d / "bin" / "gitlab-runner"
    fake.write_text(f"""#!/bin/bash
printf '%s\\n' "$@" > "{d}/argv"
printf '%s' "${{CI_SERVER_TOKEN:-}}" > "{d}/env_token"
name=""; while [ $# -gt 0 ]; do [ "$1" = --name ] && name="$2"; shift; done
printf '\\n[[runners]]\\n  name = "%s"\\n  url = "https://gitlab.com/"\\n' "$name" >> "$GITLAB_RUNNER_CONFIG"
printf '%s\\n' {fake_says!r}
exit {fake_rc}
""")
    fake.chmod(0o755)
    cfg = d / "config.toml"
    cfg.write_text(CONFIG)
    env = {**os.environ, "PATH": f"{d / 'bin'}:{os.environ['PATH']}", "GITLAB_RUNNER_CONFIG": str(cfg)}
    r = REAL_RUN(["bash", str(SCRIPT), *args], input=stdin, capture_output=True, text=True, env=env, timeout=60)
    return r.returncode, r.stdout, r.stderr, d


rc, out, err, d = host_script(["register", "test01-build", "--url", "https://gitlab.com", "--executor", "docker"],
                              FAKE_TOKEN + "\n")
argv = (d / "argv").read_text().split("\n")
cfg = (d / "config.toml").read_text()
check("script register: exit 0", rc == 0, err)
check("script register: the token is in gitlab-runner's environment", (d / "env_token").read_text() == FAKE_TOKEN)
check("script register: the token is not in its argv", FAKE_TOKEN not in "\n".join(argv))
check("script register: non-interactive, named, the options passed on",
      argv[:3] == ["register", "--non-interactive", "--name"] and "test01-build" in argv and "--executor" in argv, str(argv))
check("script register: the old local entry of that name is replaced (one left)",
      cfg.count('name = "test01-build"') == 1 and "old-entry.example" not in cfg and 'name = "test01-gone"' in cfg)
check("script register: the token is not printed", FAKE_TOKEN not in out + err)

rc, out, err, d = host_script(["register", "test01-build"], "")
check("script register: no token on stdin is refused", rc == 1 and "no runner token on stdin" in err, err)

leak = "glrt" + "-" + "placeholderpart"
rc, out, err, d = host_script(["register", "test01-build"], FAKE_TOKEN + "\n", fake_rc=1,
                              fake_says=f"Verifying runner... failed  runner={leak[5:14]} token={leak}")
check("script register: a failure's exit status comes back", rc == 1, f"rc {rc}")
check("script register: a failure's output is shown with token fragments redacted",
      "Verifying runner... failed" in err and leak not in err and leak[5:14] not in err, err)

rc, out, err, d = host_script(["finish", "test01-build"], "")
cfg = (d / "config.toml").read_text()
check("script finish: entries not named are removed, the global part kept",
      rc == 0 and 'name = "test01-gone"' not in cfg and 'name = "test01-build"' in cfg and "[session_server]" in cfg, err + cfg)
check("script finish: concurrent = the number of runners", "concurrent = 1\n" in cfg)
rc, out, err, d = host_script(["finish", "test01-build", "test01-gone"], "")
check("script finish: two runners, concurrent = 2", rc == 0 and "concurrent = 2\n" in (d / "config.toml").read_text())
rc, out, err, d = host_script(["finish"], "")
check("script finish: no names is refused", rc == 1)
rc, out, err, d = host_script(["nothing"], "")
check("script: an unknown command shows the usage", rc == 2 and "gitlab-runner.sh install" in err)
check("the build sends the script from build/gitlab-runner/, outside what the updaters install (HOST/, docker/)",
      SCRIPT.is_file() and not build_host.BUILD_GITLAB_RUNNER.startswith(("docker/", "d0", "test01/")))

print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
