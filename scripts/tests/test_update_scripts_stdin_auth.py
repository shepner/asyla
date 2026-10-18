#!/usr/bin/env python3
"""Offline test: no deploy token file outside TOKEN_FILE_HOSTS (asyla hub d06 item, action 4).

    python3 scripts/tests/test_update_scripts_stdin_auth.py

The operator's rule: no secret in any file. d04, d06 and test01's update_scripts.sh take their
GitLab read credential on stdin ("username=" and "password=" lines: host-maintenance's job token,
or the bootstrap's deploy token) and keep none; build_host.py's bootstrap hands the deploy token
that way and removes an old /etc/asyla/asyla-hosts.env; verify checks the file is absent.

Cases: each updater's credential block (between its "# >>> credential" and "# <<< credential"
lines) run alone in bash: a credential on stdin is what `git credential fill` then answers, with
or without a final newline; none, or half of one, exits 1 before git. Every updater outside
TOKEN_FILE_HOSTS has the block and names no token file; those inside still read it. The bootstrap
and the token check with ssh replaced: the credential goes only on stdin, never in a command; no
command writes the file; a dry run calls nothing. build_host.GIT_STDIN_AUTH run in bash answers
the credential it was handed. Runs bash and git locally only; no host and no GitLab. Exit 0 when
every case passes.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
os.environ["ASYLA_HOSTS_DEPLOY_USER"] = "example_user"
os.environ["ASYLA_HOSTS_DEPLOY_TOKEN"] = "example_value"
import build_host  # noqa: E402

CRED = "username=example_user\npassword=example_value\n"
FILL_IN = "protocol=https\nhost=gitlab.com\n\n"
results: list[bool] = []


def check(name: str, good: bool, detail: str = "") -> None:
    results.append(good)
    print(f"{'ok  ' if good else 'FAIL'}  {name}" + ("" if good or not detail else f"\n        {detail}"))


def stdin_hosts() -> list[str]:
    """Hosts with a spec and an updater, outside TOKEN_FILE_HOSTS."""
    return sorted(p.parent.name for p in REPO.glob("*/update_scripts.sh")
                  if (p.parent / "host.toml").is_file() and p.parent.name not in build_host.TOKEN_FILE_HOSTS)


def block(host: str) -> str:
    lines = (REPO / host / "update_scripts.sh").read_text().splitlines()
    start = [i for i, l in enumerate(lines) if l.startswith("# >>> credential")]
    end = [i for i, l in enumerate(lines) if l == "# <<< credential"]
    if len(start) != 1 or len(end) != 1 or end[0] < start[0]:
        return ""
    return "\n".join(lines[start[0]:end[0] + 1])


def run_block(host: str, stdin: str) -> subprocess.CompletedProcess:
    """The credential block alone, then what git's credential helper chain answers for gitlab.com."""
    script = ("set -euo pipefail\nlog_error() { echo \"[ERROR] $1\" >&2; }\n" + block(host) +
              f"\nprintf {FILL_IN!r} | git credential fill\n").replace("printf '", "printf $'")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["bash", "-c", script], input=stdin, capture_output=True, text=True, env=env, timeout=60)


def updater_cases() -> None:
    hosts = stdin_hosts()
    check("the stdin hosts are d04, d06 and test01", hosts == ["d04", "d06", "test01"], str(hosts))
    for host in hosts:
        text = (REPO / host / "update_scripts.sh").read_text()
        code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
        check(f"{host}: names no token file", "asyla-hosts.env" not in code and "DEPLOY_ENV" not in code)
        check(f"{host}: has one credential block", bool(block(host)))
        if not block(host):
            continue
        r = run_block(host, CRED)
        check(f"{host}: a credential on stdin is what git gets", r.returncode == 0 and
              "username=example_user" in r.stdout.splitlines() and "password=example_value" in r.stdout.splitlines(),
              f"exit {r.returncode}: {r.stderr.strip()[-200:]}")
        r = run_block(host, CRED.rstrip("\n"))
        check(f"{host}: the last line needs no newline", r.returncode == 0 and "password=example_value" in r.stdout,
              f"exit {r.returncode}")
        for name, stdin in (("no credential", ""), ("a username only", "username=example_user\n"),
                            ("other lines only", "hello\nworld\n")):
            r = run_block(host, stdin)
            check(f"{host}: {name} refuses before git", r.returncode == 1 and "No GitLab read credential" in r.stderr
                  and "username=" not in r.stdout, f"exit {r.returncode}: {r.stdout!r}")
        allf = (REPO / host / "update_all.sh").read_text()
        check(f"{host}: update_all.sh goes on when the scripts are not updated",
              '"$HOME_DIR/update_scripts.sh" || log_warn' in allf)
    for host in build_host.TOKEN_FILE_HOSTS:
        f = REPO / host / "update_scripts.sh"
        check(f"{host} (TOKEN_FILE_HOSTS): its updater still reads the file",
              f.is_file() and 'DEPLOY_ENV="/etc/asyla/asyla-hosts.env"' in f.read_text())


class R:
    def __init__(self, rc: int = 0, out: str = ""):
        self.returncode, self.stdout, self.stderr = rc, out, ""


def with_fakes(answers, call):
    """Run call() with ssh and master_file replaced; return [(target, command, stdin)]."""
    calls = []

    def fake_ssh(target, command, stdin=None, **kw):
        calls.append((target, command, stdin))
        return answers(command)

    real_ssh, real_mf = build_host.ssh, build_host.master_file
    build_host.ssh, build_host.master_file = fake_ssh, lambda rel: "#!/bin/bash\necho updater\n"
    try:
        call()
    finally:
        build_host.ssh, build_host.master_file = real_ssh, real_mf
    return calls


def bootstrap_cases() -> None:
    calls = with_fakes(lambda c: R(0), lambda: build_host.phase_bootstrap({"host": "d06"}, False))
    check("bootstrap dry run: no call to the host", calls == [], str(calls))

    calls = with_fakes(lambda c: R(0), lambda: build_host.phase_bootstrap({"host": "d06"}, True))
    cmds = [c for _, c, _ in calls]
    check("bootstrap: the token is in no command", all("example_value" not in c for c in cmds))
    check("bootstrap: no command writes the token file",
          not any(build_host.DEPLOY_ENV in c and ("cat >" in c or "mv " in c) for c in cmds), str(cmds))
    check("bootstrap: removes an old token file", any(c.startswith(f"sudo rm -f {build_host.DEPLOY_ENV}") for c in cmds))
    upd = [(c, i) for _, c, i in calls if "sudo bash /tmp/update_scripts.sh" in c]
    check("bootstrap: the updater gets the credential on stdin", len(upd) == 1 and upd[0][1] == CRED,
          str([i for _, i in upd]))
    check("bootstrap: the updater is the master file", len(upd) == 1 and "| base64 -d > /tmp/update_scripts.sh" in upd[0][0])
    check("bootstrap: no other call gets the credential", sum(1 for _, _, i in calls if i == CRED) == 1)

    def file_host(c):
        return R(0, "root:root 600 0123456789abcdef refs/heads/master") if "stat -c" in c else R(0)
    calls = with_fakes(file_host, lambda: build_host.phase_bootstrap({"host": "d03"}, True))
    check("bootstrap of d03 (TOKEN_FILE_HOSTS): still installs the file",
          any(f"cat > {build_host.DEPLOY_ENV}.tmp" in c for _, c, _ in calls))


def check_cases() -> None:
    calls = with_fakes(lambda c: R(0, "0123456789abcdef\trefs/heads/master\n"),
                       lambda: build_host.check_stdin_read("d06"))
    check("token check: the credential on stdin only", len(calls) == 1 and calls[0][2] == CRED
          and "example_value" not in calls[0][1], str(calls))
    got = []
    with_fakes(lambda c: R(1), lambda: got.append(build_host.token_file_absent("d06")))
    with_fakes(lambda c: R(0), lambda: got.append(build_host.token_file_absent("d06")))
    with_fakes(lambda c: R(255), lambda: got.append(build_host.token_file_absent("d06")))
    check("verify: absent only when test -e says so (1), not on ssh failure (255)", got == [True, False, False], str(got))
    calls = with_fakes(lambda c: R(0), lambda: build_host.remove_token_file("d06", False))
    check("token dry run: no call to the host", calls == [])

    # GIT_STDIN_AUTH as the remote bash runs it, locally.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    script = build_host.GIT_STDIN_AUTH + "; printf $'protocol=https\\nhost=gitlab.com\\n\\n' | git credential fill"
    r = subprocess.run(["bash", "-c", script], input=CRED, capture_output=True, text=True, env=env, timeout=60)
    check("GIT_STDIN_AUTH: git gets the handed credential", r.returncode == 0 and
          "username=example_user" in r.stdout.splitlines() and "password=example_value" in r.stdout.splitlines(),
          f"exit {r.returncode}: {r.stderr.strip()[-200:]}")


if __name__ == "__main__":
    updater_cases()
    bootstrap_cases()
    check_cases()
    print(f"{sum(results)}/{len(results)} passed")
    sys.exit(0 if all(results) else 1)
