#!/usr/bin/env python3
"""Offline test of two cutover gaps in build_host.py:

- the restore phase stops the build on a failed restore (gap (c)): a refusal because the data dir
  holds data is a skip (a re-run), any other failure is a Fail before any later phase runs;
  restore_command() is run by local bash against fake app scripts and the real
  docker/backup_lib.sh refusals;
- the Gitea host (gap (f)): GITEA_TOKEN_HOST is the default, --gitea-host overrides it for one
  build, and the runner phase checks that the Gitea host serves gitea.asyla.org before it deletes,
  installs or registers anything.

    python3 scripts/tests/test_build_host_restore_gitea_host.py

Nothing reaches a host, GitLab or Gitea: subprocess and urlopen are replaced so that a stray call
fails the test. The registration token of the fakes is built from parts and is no token. Exit 0
when every case passes.
"""
from __future__ import annotations

import contextlib
import io
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the test reached out: {a[:1]}")


REAL_RUN = build_host.subprocess.run   # the wrapper cases run local bash only
build_host.subprocess.run = _no_contact
build_host.urllib.request.urlopen = _no_contact

FAKE_TOKEN = "-".join(["fake", "registration", "value"])   # a placeholder, built from parts
results: list[bool] = []


def check(name: str, good: bool, detail: str = "") -> None:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    results.append(good)


class Done:
    def __init__(self, rc: int, out: str = ""):
        self.returncode, self.stdout, self.stderr = rc, out, ""


@contextlib.contextmanager
def patched(**fakes):
    """Replace build_host attributes for the block; stdout is captured into the yielded buffer."""
    real = {k: getattr(build_host, k) for k in fakes}
    for k, v in fakes.items():
        setattr(build_host, k, v)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            yield buf
    finally:
        for k, v in real.items():
            setattr(build_host, k, v)


def run_wrapper(body: str) -> int:
    """restore_command() of a fake app script with BODY, run by local bash; its exit status."""
    d = Path(tempfile.mkdtemp(prefix="build-host-restore-"))
    script = d / "app.sh"
    script.write_text(f"#!/bin/bash\n[ \"$1\" = restore ] || exit 9\n{body}\n")
    script.chmod(0o755)
    r = REAL_RUN(["bash", "-c", build_host.restore_command(str(script))], capture_output=True, text=True, timeout=60)
    return r.returncode


# ---------------------------------------------------------------- gap (c): the restore wrapper

lib = (build_host.REPO / "docker" / "backup_lib.sh").read_text()
check("the skip marker is backup_lib.sh's refusal of a data dir that holds data",
      f"[ERROR] $dest {build_host.RESTORE_NOT_EMPTY} (RESTORE_FORCE=1 to overwrite)" in lib)
check("wrapper: a restore that succeeds exits 0", run_wrapper('echo "[INFO] Restore complete: /x"') == 0)
check("wrapper: a refusal of a non-empty data dir is a skip",
      run_wrapper(f'echo "[ERROR] /x {build_host.RESTORE_NOT_EMPTY} (RESTORE_FORCE=1 to overwrite)" >&2; exit 1')
      == build_host.RESTORE_SKIPPED)
check("wrapper: no backup is a failure",
      run_wrapper('echo "[ERROR] No backup at /m (no .backup-status)" >&2; exit 1') == 1)
check("wrapper: a backup not OK is a failure",
      run_wrapper('echo "[ERROR] Last backup at /m is not complete: IN PROGRESS" >&2; exit 1') == 1)
check("wrapper: the app's own exit 3 cannot pass for a skip", run_wrapper("exit 3") == 1)
check("wrapper: another exit keeps its status", run_wrapper("exit 7") == 7)


def lib_case(name: str, status: str | None, dest_files: bool, want: int) -> None:
    """The real do_rsync_mirror_restore up to its refusals (both come before its lock and rsync)."""
    d = Path(tempfile.mkdtemp(prefix="build-host-restore-lib-"))
    (d / "mirror").mkdir()
    (d / "dest").mkdir()
    if status is not None:
        (d / "mirror" / ".backup-status").write_text(status + "\n")
    if dest_files:
        (d / "dest" / "data").write_text("x\n")
    body = (f'. {build_host.shlex.quote(str(build_host.REPO / "docker" / "backup_lib.sh"))}\n'
            f'do_rsync_mirror_restore {d / "mirror"} {d / "dest"} || exit $?')
    got = run_wrapper(body)
    check(f"backup_lib: {name}", got == want, f"exit {got}, want {want}")


lib_case("an OK backup over a data dir that holds data: a skip", "OK 2026-10-16T00:00:00+00:00 from d03:/x", True,
         build_host.RESTORE_SKIPPED)
lib_case("no .backup-status: a failure", None, False, 1)
lib_case("a backup IN PROGRESS: a failure", "IN PROGRESS since 2026-10-16T00:00:00+00:00", False, 1)

# ---------------------------------------------------------------- gap (c): the phase and the build

SPEC = build_host.load_spec("test01")
APP = SPEC["app"][0]["name"]


def restore_phase(rc: int) -> tuple[str, list, str]:
    """phase_restore(--apply) with the app's restore exiting RC: (Fail text or "", secrets calls, output)."""
    calls, secrets = [], []

    def ssh(t, c, **kw):
        calls.append(c)
        return Done(0) if c.startswith("grep ") else Done(rc)

    def secrets_cmd(*a, **kw):
        secrets.append(a)
        return 0
    failed = ""
    with patched(ssh=ssh, secrets_cmd=secrets_cmd) as out:
        try:
            build_host.phase_restore(SPEC, True)
        except build_host.Fail as e:
            failed = str(e)
    ran_wrapper = any(c.startswith("bash -c ") and "restore 2>&1 | tee" in c for c in calls)
    return failed if ran_wrapper else "the restore did not run through restore_command", secrets, out.getvalue()


f, sec, out = restore_phase(0)
check("restore phase: a restore that succeeds goes on to the data secrets", f == "" and len(sec) == 1, f)
f, sec, out = restore_phase(build_host.RESTORE_SKIPPED)
check("restore phase: a data dir that holds data is skipped, then the data secrets",
      f == "" and len(sec) == 1 and "skipped, its data dir is not empty" in out, f or out)
for rc in (1, 255):
    f, sec, out = restore_phase(rc)
    check(f"restore phase: exit {rc} stops it, before the data secrets",
          f.startswith(f"restore {APP}: exit {rc}") and "stopped before any app starts" in f and not sec, f)


def build_from_restore(rc: int) -> tuple[int, list[str], str]:
    """main() for `test01 build --from restore --apply` with the restore exiting RC and every later
    phase a recorder: (exit, the later phases that ran, stderr)."""
    ran = []

    def rec(name, ret=None):
        return lambda *a, **kw: ran.append(name) or ret

    def ssh(t, c, **kw):
        return Done(0) if c.startswith("grep ") else Done(rc)
    err = io.StringIO()
    argv, sys.argv = sys.argv, ["build_host.py", "test01", "build", "--from", "restore", "--apply"]
    try:
        with patched(ssh=ssh, secrets_cmd=lambda *a, **kw: 0, phase_apps=rec("apps"),
                     phase_external=rec("external", 0), phase_runner=rec("runner"), verify=rec("verify", 0)):
            with contextlib.redirect_stderr(err):
                code = build_host.main()
    finally:
        sys.argv = argv
    return code, ran, err.getvalue()


code, ran, err = build_from_restore(1)
check("build: a failed restore exits 1 and no later phase runs",
      code == 1 and ran == [] and f"FAILED: restore {APP}: exit 1" in err, f"exit {code}, ran {ran}, {err.strip()}")
code, ran, err = build_from_restore(build_host.RESTORE_SKIPPED)
check("build: a skipped restore goes on through every later phase",
      code == 0 and ran == ["apps", "external", "apps", "runner", "verify"], f"exit {code}, ran {ran}, {err.strip()}")

# ---------------------------------------------------------------- gap (f): the Gitea host


def parse(line: str):
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            return build_host.parse_args(line.split())
    except SystemExit as e:
        return f"exit {e.code}: {err.getvalue().strip().splitlines()[-1]}"


check("the default Gitea host is d03 until the cutover", build_host.GITEA_TOKEN_HOST == "d03")
check("the Gitea hosts are the specs with a gitea app and no replica", build_host.gitea_hosts() == ["d03", "d04"],
      str(build_host.gitea_hosts()))
check("the name the runners register against", build_host.GITEA_NAME == "gitea.asyla.org"
      and f'GITEA_INSTANCE_URL="https://{build_host.GITEA_NAME}"'
      in (build_host.REPO / "docker/gitea-runner/gitea-runner.sh").read_text())
a = parse("test01 build --apply")
check("no --gitea-host: none given", not isinstance(a, str) and a.gitea_host is None, str(a))
a = parse("test01 build --only runner --gitea-host d04")
check("--gitea-host d04 is taken", not isinstance(a, str) and a.gitea_host == "d04", str(a))
for line, needle in (("test01 build --gitea-host test01", "not a host whose spec has a gitea"),
                     ("test01 build --gitea-host d01", "not a host whose spec has a gitea"),
                     ("test01 verify --gitea-host d04", "is for build")):
    a = parse(line)
    check(f"refused: build_host.py {line}", isinstance(a, str) and a.startswith("exit 2") and needle in a, str(a))

got = []
with patched(phase_gitea_runner=lambda s, ap, h: got.append(h), phase_gitlab_runner=lambda s, ap: None):
    build_host.phase_runner(SPEC, False, None)
    build_host.phase_runner(SPEC, False, "d04")
check("the runner phase: no --gitea-host resolves to GITEA_TOKEN_HOST, a given one is used", got == ["d03", "d04"], str(got))


def serving(out: str, rc: int = 0) -> str:
    """require_serving_gitea("d03") with the host's answer OUT: "" when it passes, else the Fail."""
    seen = []
    with patched(ssh=lambda t, c, **kw: seen.append((t, c)) or Done(rc, out)):
        try:
            build_host.require_serving_gitea("d03")
        except build_host.Fail as e:
            return str(e)
    return "" if seen == [("d03", build_host.GITEA_SERVING_SH)] else f"asked {seen}"


check("serving: the name resolves to one of the host's own addresses", serving("10.0.0.62 \n10.0.0.62 172.17.0.1\n") == "")
for name, out, rc in (("another host's address (d04 before the cutover)", "10.0.0.62 \n10.0.0.63 172.17.0.1\n", 0),
                      ("the name does not resolve there", "\n10.0.0.62\n", 0),
                      ("the host does not answer", "", 255)):
    f = serving(out, rc)
    check(f"serving refused: {name}", f.startswith("Gitea host d03: gitea.asyla.org resolves there to"), f)


def gitea_runner(gitea_host: str, answers: dict[str, str]) -> tuple[str, list[str]]:
    """phase_gitea_runner(test01, --apply, GITEA_HOST) on a host not registered yet. ANSWERS: the
    serving check's output per host. Returns (Fail text or "", the actions in order)."""
    acts = []

    def ssh(t, c, stdin=None, **kw):
        if "/var/lib/gitea-runner/.runner" in c:
            return Done(1)
        if c == build_host.GITEA_SERVING_SH:
            acts.append(f"serving? {t}")
            return Done(0, answers[t])
        if "generate-runner-token" in c:
            acts.append(f"token from {t}")
            return Done(0, FAKE_TOKEN + "\n")
        raise AssertionError(f"unexpected ssh {t}: {c[:60]}")

    def build_run(host, paths, command, as_root, stdin=None):
        sw = command.split()[-1]
        acts.append(f"runner {sw}" + (" (token on stdin)" if stdin == FAKE_TOKEN + "\n" else ""))
    failed = ""
    with patched(ssh=ssh, build_run=build_run, delete_runner_entry=lambda h, ap: acts.append(f"delete entry {h}")):
        try:
            build_host.phase_gitea_runner(SPEC, True, gitea_host)
        except build_host.Fail as e:
            failed = str(e)
    return failed, acts


ANSWERS = {"d03": "10.0.0.62 \n10.0.0.62 172.17.0.1\n", "d04": "10.0.0.62 \n10.0.0.63 172.17.0.1\n"}
f, acts = gitea_runner("d03", ANSWERS)
check("runner, Gitea host d03 (today): checked, entry deleted, installed, token from d03 over stdin, up",
      f == "" and acts == ["serving? d03", "delete entry test01", "runner install", "token from d03",
                           "runner register (token on stdin)", "runner up"], f or str(acts))
f, acts = gitea_runner("d04", ANSWERS)
check("runner, Gitea host d04 before the cutover: stops before deleting, installing or a token",
      f.startswith("Gitea host d04:") and acts == ["serving? d04"], f or str(acts))
f, acts = gitea_runner("d04", {"d04": "10.0.0.63 \n10.0.0.63 172.17.0.1\n"})
check("runner, Gitea host d04 after the name moves: the token comes from d04",
      f == "" and "token from d04" in acts and "token from d03" not in acts, f or str(acts))

print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
