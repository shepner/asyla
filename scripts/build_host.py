#!/usr/bin/env python3
"""Build, rebuild and verify a Docker host (d0N, or the test host test01) from its spec, from the workstation.

asyla hub decisions/host-build-and-recovery.md: a rebuild must reproduce everything a host runs,
from nothing but GitLab (this repo, its CI/CD variables), the NAS backups and the hypervisor.

Usage:
  build_host.py HOST plan                      # read-only: spec, live VM, gaps
  build_host.py HOST build [--apply] [--from PHASE] [--only PHASE] [--recreate [--confirm HOST]]
  build_host.py HOST build --only apps|late --app NAME [--app NAME...] [--apply]   # those apps only
  build_host.py HOST build --only setup --step SCRIPT [--step SCRIPT...] [--apply]  # those setup steps only
                           [--node NODE] [--gitea-host HOST]
  build_host.py HOST verify                    # read-only
  build_host.py HOST token [--apply]           # TOKEN_FILE_HOSTS: deploy token file, then a GitLab read check;
                                               # others: remove any old file, then a read check (token on stdin)
  build_host.py HOST scripts-check             # read-only: ~/scripts vs GitLab master, file by file
  build_host.py HOST secrets check|push|install [--apply] [VAR ...]
  build_host.py HOST secrets check --keys [VAR ...]          # read-only: per key of a dotenv secret, its state only
  build_host.py HOST secrets copy [--apply] VAR FROM_VAR   # VAR created in GitLab from FROM_VAR's value
  build_host.py HOST destroy --apply [--confirm HOST]

Build phases, in order (each is safe to re-run):
  vm         create the VM from HOST/host.toml (skipped when it exists; --recreate destroys it
             first: allowed freely only for a spec with disposable = true, else needs --confirm HOST)
  bootstrap  the host's update_scripts.sh from GitLab master (the file the host will keep running),
             with the deploy token on its stdin; no token file is written, and an old one is
             removed. TOKEN_FILE_HOSTS (d01-d03, whose updaters still read it) get the file
             /etc/asyla/asyla-hosts.env first, as before.
  disk       data disk -> /mnt/docker (build/setup/data_disk.sh; never formats a disk with data)
  secrets    every [[secret]] from GitLab CI/CD variables to its path, except those under
             /mnt/docker/ (app data), which restore installs after the data is back
  setup      build/setup/<step> for each [setup].steps, as root; then, for a spec with
             [host_maintenance], build/setup/host_maintenance_keys.sh (below)
  restore    `<app>.sh restore` for each app whose data is empty (from its NAS mirror), then the
             secrets under /mnt/docker/. An app that refuses because its data dir holds data is
             skipped (a re-run); any other failure (no backup, a backup not "OK", rsync) stops
             the build before any app starts (exit 1): an app must never start on empty data.
             Each restore may take RESTORE_TIMEOUT (7200 s), or its [[app]] restore_timeout =
             SECONDS (d02's Plex: 291G from its mirror)
  apps       each app's start commands (default: up), in spec order, except the apps marked
             after_external = true
  external   other repos' deploy commands from the workstation; `manual` entries are listed
             (verify runs an entry's `check` on the host, else notes a manual entry, never FAIL).
             An entry's env = ["NAME"...] names values its commands take from build_host.py's
             environment (they inherit it): d06's proxy key, which internal-access's fleet.sh
             sends over SSH stdin (no .env on d06)
  late       the apps marked after_external = true: those that need this host's proxy or tunnel
             up before they start (an app that pulls its images through the proxy)
  runner     Gitea runner: check that the Gitea host serves gitea.asyla.org (below), delete this
             host's stale entry, install, register (token from the Gitea host), up; then each
             [gitlab_runner] runner: delete GitLab's entries with its description (HOST-NAME),
             create a new one (POST /user/runners, untagged jobs off, ref_protected), register it on the host
             (build/gitlab-runner/gitlab-runner.sh; the token over SSH stdin, into gitlab-runner's
             environment), concurrent = the number of runners, wait until online
  verify     mounts, every app's verify (or running containers), runners online with the spec's
             labels or tags, the host-maintenance key set

Pre-flight: a build that includes the vm phase first compares every [[secret]] file on the
live host (for a replica: on its source) with its GitLab variable, by hash, and stops when one
differs or exists on the host only: the rebuild would install another value than the host runs
with, or none. A host that does not answer (a first build) has nothing to compare.

Build files: one set of base build scripts in build/setup/, and a host is its HOST/host.toml
(asyla hub, the rules gap "build new and cut over"). The disk, setup and runner phases send what
they need from GitLab master (`git archive` of build/, HOST/host.toml and, for the runner,
docker/gitea-runner/) inside the SSH command, unpack it into a mktemp folder that a trap removes,
and run from there with HOST_SPEC set; nothing of the build stays on the host, and verify checks
that. GitLab runners the same way: build/gitlab-runner/ is sent, never kept (the updaters install
only HOST/ and docker/), and the host keeps only the gitlab-runner package, its apt source and
key, /etc/gitlab-runner/config.toml and the unit. LEGACY_HOSTS is empty: d03 (2026-10-17), d01
and d02 (2026-10-18) each left it for their rebuilds. A host in it would keep HOST/setup/ and its
old phases until replaced (operator: "Let the legacy servers behave in their legacy ways"); any
other spec is refused if HOST/setup/ exists or a step is not in build/setup/.

Gitea host: the host whose Gitea container makes the runner registration token
(GITEA_TOKEN_HOST, d04 since the 2026-10-16 cutover from d03; --gitea-host HOST for one build, a host whose
spec has a gitea [[app]] and no [replica]). The runner registers against the name
gitea.asyla.org, so the token must come from the Gitea that name reaches: before it deletes or
registers anything, the runner phase resolves the name on the Gitea host and stops unless one
address is that host's own (the rule of d04's gitea.sh backup guard). A wrong value, a flip made
before the name moves or forgotten after it, stops there.

Start order: an optional [vm].startup (Proxmox's form, "order=N[,up=S][,down=S]") is set when the
VM is created and checked by verify.

Node: [vm].node is where the VM is created. --node NODE overrides it for a spec with
disposable = true only (the test host may run on either node); a production host's node is its
spec's. Hold: a spec with a top-level hold = "reason" is not built or destroyed.

Guests are reached as docker@HOST with ~/.ssh/docker_rsa, the user and key the vm phase gives
them, so a host needs no entry in the workstation's ssh config.

App environment (no secret on the host or in a file, asyla SEC-5): an [[app]] may name values
that build_host.py takes from its own environment (the credentials capability puts them there)
and sends over SSH stdin, so they exist only in that one command's process environment on the
host, never in a command line, a file or this output; an unset one fails, naming it.
  pull_token_env = "NAME"  a registry pull token, handed to the app script as
                           <APP>_REGISTRY_PULL_TOKEN (APP upper-cased, "-" as "_"): for `APP.sh
                           images` before its restore (restore pulls nothing itself), in a
                           replica's image pull, and for its start commands (missing images)
  start_env = ["NAME"...]  values only the start commands (apps and late phases) get, under their
                           own names; never on a replica (it runs no vault parts), where they are
                           neither read nor sent
d06's ticketing: pull_token_env = "THEORG_REGISTRY_PULL_TOKEN", start_env = its two Dex client
values (d06/apps/ticketing/README.md).

Replica: a spec with [replica] of = "dNN" (test01 as a d03 replica) takes the source spec's
[[secret]] and [[app]] lists (minus exclude_secrets) and runs the apps from ~/scripts/dNN/ (its
updater installs that tree too). Its own [vm] and [setup] apply, and the source's [[external]]
never do: a replica must not answer for the source's hostnames. With start_apps = false the apps
phase starts nothing and verify checks that no container runs. [replica] keys: of, start_apps,
exclude_secrets, apps (names: only these of the source's apps), gitea_config, verify, app_verify.
A replica writes nothing outward: before any app starts, the apps phase pulls the started apps'
missing images (an app script with an `images` switch pulls and lists its own), then applies build/setup/replica_egress.sh (nftables: the host reaches the LAN
and its containers only, containers reach nothing off the host; a oneshot unit keeps it across
boots) and checks that the host and each image cannot reach the internet; then
[replica.gitea_config] (a table per app.ini section, e.g. "cron.update_mirrors" = {ENABLED = false})
goes into the restored app.ini with Gitea's own environment-to-ini, and each key is read back.
Any failure stops the build before an app starts. So a replica has no [runner] and no
[gitlab_runner] (both need the internet; refused). verify, for a replica, never runs the
source's app verify (it curls the source's public URLs): it checks that each app runs (not one
with start = [], which runs no container), waits for each [replica.verify] URL
("http://{ip}:PORT/..." or "http://127.0.0.1:PORT/...", curled on the host), checks the egress block from the host and each running container (one with no shell
by the host's curl in its network namespace) in place of the deploy token, and reads
gitea_config back. [replica].app_verify names the apps whose own verify knows a replica (checks
local answers only and refuses nothing a replica lacks: ns02's pihole, which resolves names
on the host and checks DHCP is off); for those, verify runs the app's own verify switches
instead of only checking that it runs.

GitLab runners: [gitlab_runner] runners = [{name, scope = "group:PATH" | "project:GROUP/PROJECT",
tags, executor = "docker" | "shell", and for docker image, volumes, pull_policy}]. A rebuild
makes new runners (no GitLab CI secret holds a runner token); destroy deletes them. Listings are
type-filtered (/groups/ID/runners?type=group_type): unfiltered, gitlab.com's shared runners
fill the first page.

host-maintenance key set (gap G11): a host that carries asyla/host-maintenance's runner has
[host_maintenance] identity = "PATH" (the private key: the path of one [[secret]], mode 600, not
under /mnt/docker/), user = "NAME" (whose ~/.ssh/authorized_keys gets the public key: the host
is one the jobs manage) and known_hosts = ["ADDRESS ssh-ed25519 KEY", ...] (the managed hosts'
keys, pinned), and optionally self_address = "ADDRESS" (this host's own [vm] ip, never also
pinned) when the jobs manage the runner's own host: a rebuilt host has a new host key, which no
spec can pin in advance (d03, operator 2026-10-17: the interim key set). The setup phase runs
build/setup/host_maintenance_keys.sh: IDENTITY.pub from `ssh-keygen -y`, known_hosts beside the
key from the pins, then, with self_address, the host's own ed25519 key (read on the host from
HM_HOST_KEY) as "ADDRESS ssh-ed25519 KEY", the authorized_keys line (marked HM_MARK, once), modes
0700/0600/0644 with the secret's owner; then it scans each known_hosts address (its own too) from
the host and fails on a host that does not answer or offers another key. verify checks the .pub,
the modes, the authorized_keys line and known_hosts against the spec (the pins, then the own key
as the host's HM_HOST_KEY reads at verify).

Nothing here prints a secret (SEC): tokens and secret files move over SSH stdin or HTTPS bodies.
Credentials come from the environment only (no credential file is read): GITLAB_TOKEN,
GITEA_TOKEN, ASYLA_HOSTS_DEPLOY_USER / ASYLA_HOSTS_DEPLOY_TOKEN. In the asyla hub, from inside
~/local/asyla (the vault client finds the hub from the working directory):
  python3 core/tools/credentials.py exec GITLAB_TOKEN GITEA_TOKEN ASYLA_HOSTS_DEPLOY_USER \
    ASYLA_HOSTS_DEPLOY_TOKEN -- python3 projects/asyla-hosts/scripts/build_host.py HOST ...

Exit: 0 ok, 1 a step or check failed, 2 usage or spec error.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
GITLAB_PROJECT = "asyla/asyla-hosts"
GITLAB_API = "https://gitlab.com/api/v4"
GITEA_API = "https://gitea.asyla.org/api/v1"
GITEA_TOKEN_HOST = "d04"   # the default Gitea host (docstring, "Gitea host"); d04 since the 2026-10-16 cutover
GITEA_NAME = urllib.parse.urlsplit(GITEA_API).hostname   # what runners register against
# On the Gitea host: line 1 the name's IPv4 addresses, line 2 the host's own (gitea.sh's guard).
GITEA_SERVING_SH = (f"getent ahostsv4 {GITEA_NAME} | awk '{{print $1}}' | sort -u | tr '\\n' ' '; echo; "
                    "hostname -I")
# docker/backup_lib.sh do_rsync_mirror_restore's refusal of a data dir that holds data: the one
# restore failure a build re-run expects. restore_command() turns it into RESTORE_SKIPPED.
RESTORE_NOT_EMPTY = "is not empty; refusing to restore over it"
RESTORE_SKIPPED = 3
RESTORE_TIMEOUT = 7200   # seconds for one app's restore over SSH; [[app]] restore_timeout overrides it
LEGACY_HOSTS: tuple[str, ...] = ()   # HOST/setup/ on the host, run from ~/scripts (the old way); d03, d01, d02 left it for their rebuilds
BUILD_SETUP = "build/setup"
BUILD_GITLAB_RUNNER = "build/gitlab-runner"
GITLAB_URL = "https://gitlab.com"
GL_RUNNER_NAME = re.compile(r"[a-z0-9][a-z0-9-]*")
GL_RUNNER_SCOPE = re.compile(r"(group|project):[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*")
GL_RUNNER_TAG = re.compile(r"[A-Za-z0-9_.:-]+")
GL_EXECUTORS = ("docker", "shell")
GL_PULL_POLICIES = ("always", "if-not-present", "never")
GL_ACCESS_LEVEL = "ref_protected"  # build-registered runners take protected refs only, as the live ones (operator, 2026-10-17)
HM_SCRIPT = "host_maintenance_keys.sh"   # build/setup/, run by the setup phase for [host_maintenance]
HM_MARK = "asyla-build:host-maintenance"  # the end of its authorized_keys line (the script's MARK)
HM_PIN = re.compile(r"[A-Za-z0-9.:-]+ ssh-ed25519 [A-Za-z0-9+/]+={0,2}")
HM_PATH = re.compile(r"/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+")
HM_NAME = re.compile(r"[a-z_][a-z0-9_-]*")
HM_HOST_KEY = "/etc/ssh/ssh_host_ed25519_key.pub"   # the host's own key, pinned at [host_maintenance].self_address
GL_ONLINE_WAIT = 180           # seconds the runner phase waits for a new GitLab runner to be online
NODES = ("vmh01", "vmh02")
# Proxmox's lowest guest id (inference from its tooling, not checked in its docs): load_spec
# refuses a lower [vm].vmid, so a placeholder 0 can never build.
MIN_VMID = 100
IMAGE = "/mnt/nas/data1/iso/template/iso/debian-13-generic-amd64.qcow2"
GATEWAY = "10.0.0.1"
NAMESERVERS = "10.0.0.10 10.0.0.11"
SEARCHDOMAIN = "asyla.org"
BRIDGE, VLAN = "vmbr1", 100
SSH_KEY_PUB = Path.home() / ".ssh/docker_rsa.pub"
SSH_KEY = SSH_KEY_PUB.with_suffix("")
GUEST_USER = "docker"
DEPLOY_ENV = "/etc/asyla/asyla-hosts.env"
# Hosts whose update_scripts.sh still reads DEPLOY_ENV (asyla hub backlog: the d01-d03 deploy token
# file). Every other host keeps no token: its updater takes the credential on stdin, from
# host-maintenance's scripts task (the job token) or the bootstrap (the deploy token).
TOKEN_FILE_HOSTS = ("d01", "d02", "d03")
DATA_ROOT = "/mnt/docker/"
PHASES = ("vm", "bootstrap", "disk", "secrets", "setup", "restore", "apps", "external", "late", "runner", "verify")
STARTUP_FORM = re.compile(r"order=\d+(,up=\d+)?(,down=\d+)?")
REPLICA_KEYS = ("of", "start_apps", "exclude_secrets", "apps", "gitea_config", "verify", "app_verify")
REPLICA_EGRESS = "replica_egress.sh"   # build/setup/, run by the apps phase of a replica
REPLICA_EGRESS_UNIT = "asyla-replica-egress.service"
REPLICA_EGRESS_TABLE = "inet asyla_replica_egress"
EGRESS_PROBES = ("https://gitlab.com", "https://github.com")   # a replica must reach neither
# curl, else wget, else python3 (d03's app images have only python3: the 2026-10-17 d03 proof);
# 99: none exists, or python3 failed otherwise than on the network (no proof). $0 is the URL.
# python3 as curl without -f: an HTTP error status is an answer, so the URL was reached (exit 0).
EGRESS_PROBE_PY = ("import sys\n"
                   "try:\n"
                   "    import urllib.request\n"
                   "    urllib.request.urlopen(sys.argv[1], timeout=5)\n"
                   "except Exception as e:\n"
                   "    sys.exit(0 if type(e).__name__ == 'HTTPError' else 1 if isinstance(e, OSError) else 99)\n")
EGRESS_PROBE_SH = ('if command -v curl >/dev/null 2>&1; then curl -s -o /dev/null -m 5 "$0"; '
                   'elif command -v wget >/dev/null 2>&1; then wget -q -T 5 -O /dev/null "$0"; '
                   f'elif command -v python3 >/dev/null 2>&1; then python3 -c "{EGRESS_PROBE_PY}" "$0"; '
                   'else exit 99; fi')
# docker run/exec's exit when the image has no `sh` (vikunja's image: one static binary).
NO_SHELL = 127
# A running container with no shell: the host's curl in that container's network namespace. Every
# step that cannot run is 99 (no proof), so a failure of the tooling never reads as "blocked".
NSENTER_PROBE = ('pid=$(docker inspect -f "{{{{.State.Pid}}}}" {c}) || exit 99; [ "$pid" -gt 0 ] 2>/dev/null || exit 99; '
                 'sudo -n nsenter -t "$pid" -n true || exit 99; command -v curl >/dev/null || exit 99; '
                 'sudo -n nsenter -t "$pid" -n curl -s -o /dev/null -m 5 {url}')
INI_SECTION = re.compile(r"[a-z][a-z0-9_]*(\.[a-z0-9_]+)*")
INI_KEY = re.compile(r"[A-Z][A-Z0-9_]*")
INI_VALUE = re.compile(r"[A-Za-z0-9._:/,@-]*")
ENV_NAME = re.compile(r"[A-Z_][A-Z0-9_]*")   # [[app]] pull_token_env, start_env
# d03's gitea compose mounts ${DOCKER_DL}/Gitea/data at /data.
GITEA_INI = "/data/gitea/conf/app.ini"
GITEA_INI_HOST = "/mnt/docker/Gitea/data/gitea/conf/app.ini"
# Prints {"section.KEY": value or null} for the asked keys only (app.ini holds secrets: never the file).
INI_READ_PY = ("import configparser, json, sys\n"
               "c = configparser.ConfigParser(interpolation=None, strict=False, allow_no_value=True)\n"
               "c.read_string('[__root__]\\n' + open(sys.argv[1]).read())\n"
               "print(json.dumps({s + '.' + k: c.get(s, k, fallback=None) for s, k in json.loads(sys.argv[2])}))\n")
COMPOSE_ENV = '[ -f ~/scripts/docker/common.env ] && . ~/scripts/docker/common.env; export DOCKER_DL="${DOCKER_DL:-/mnt/docker}"'
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]


class Fail(Exception):
    pass


# ---------------------------------------------------------------- environment and remote calls

CREDENTIALS = ("GITLAB_TOKEN", "GITEA_TOKEN", "ASYLA_HOSTS_DEPLOY_USER", "ASYLA_HOSTS_DEPLOY_TOKEN")


def need(key: str) -> str:
    v = os.environ.get(key, "")
    if not v:
        raise Fail(f"{key} is not in the environment; run through the credentials capability, from inside "
                   f"~/local/asyla: python3 core/tools/credentials.py exec {' '.join(CREDENTIALS)} -- "
                   f"python3 projects/asyla-hosts/scripts/build_host.py ...")
    return v


def run(cmd: list[str], stdin: str | None = None, timeout: int = 1800, check: bool = True,
        quiet: bool = False) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, input=stdin if stdin is not None else "", capture_output=True,
                       text=True, timeout=timeout)
    if check and r.returncode != 0:
        if not quiet:
            sys.stderr.write(r.stdout[-3000:] + r.stderr[-3000:])
        raise Fail(f"exit {r.returncode}: {' '.join(cmd[:6])}...")
    return r


def ssh_argv(target: str) -> list[str]:
    """The ssh command for a target: user@host as given (a node), or a bare guest name, which is
    reached as GUEST_USER with SSH_KEY whatever the workstation's ssh config says of that name."""
    if "@" in target:
        return SSH + [target]
    return SSH + ["-i", str(SSH_KEY), f"{GUEST_USER}@{target}"]


def ssh(target: str, command: str, stdin: str | None = None, timeout: int = 1800,
        check: bool = True, stream: bool = False) -> subprocess.CompletedProcess:
    if stream:
        r = subprocess.run(ssh_argv(target) + [command], input=stdin if stdin is not None else "",
                           text=True, timeout=timeout)
        if check and r.returncode != 0:
            raise Fail(f"exit {r.returncode} on {target}: {command[:80]}")
        return r
    return run(ssh_argv(target) + [command], stdin=stdin, timeout=timeout, check=check)


def root(node: str) -> str:
    return f"root@{node}"


HTTP_RETRY_WAITS = (2, 5)          # seconds before the second and third attempt


def http(method: str, url: str, headers: dict, body: dict | None = None) -> tuple[int, object]:
    """One API call. An HTTP status, error or not, is returned for the caller to judge. A
    connection error (refused, reset, DNS, TLS, timeout) is retried twice for GET, PUT and
    DELETE, which are safe to repeat; a POST is not, since the first attempt may have been
    applied. A connection error that remains is a Fail, not a traceback."""
    req = urllib.request.Request(url, method=method, headers={**headers, "Content-Type": "application/json"},
                                 data=json.dumps(body).encode() if body is not None else None)
    waits = HTTP_RETRY_WAITS if method in ("GET", "PUT", "DELETE") else ()
    for attempt in range(len(waits) + 1):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read().decode()
                return r.status, (json.loads(raw) if raw.strip() else {})
        except urllib.error.HTTPError as e:
            raw = e.read().decode()[:500]
            try:
                return e.code, json.loads(raw)
            except json.JSONDecodeError:
                return e.code, raw
        except OSError as e:           # URLError, timeouts, ssl.SSLError, ConnectionError
            where = f"{method} {url.split('?')[0]}"
            if attempt == len(waits):
                raise Fail(f"{where}: connection error after {attempt + 1} attempt(s): {e}") from None
            print(f"  {where}: connection error ({e}); retrying in {waits[attempt]}s", flush=True)
            time.sleep(waits[attempt])
    raise AssertionError("unreachable")


def gitlab(method: str, path: str, body: dict | None = None) -> tuple[int, object]:
    return http(method, GITLAB_API + path, {"PRIVATE-TOKEN": need("GITLAB_TOKEN")}, body)


def gitea(method: str, path: str) -> tuple[int, object]:
    return http(method, GITEA_API + path, {"Authorization": f"token {need('GITEA_TOKEN')}"})


def step(msg: str) -> None:
    print(f"\n== {msg}", flush=True)


# ---------------------------------------------------------------- spec

def load_spec(host: str, node: str | None = None) -> dict:
    path = REPO / host / "host.toml"
    if not path.is_file():
        raise Fail(f"no spec: {path}")
    spec = tomllib.loads(path.read_text())
    spec["host"] = host
    vm = spec.get("vm", {})
    for k in ("node", "vmid", "sockets", "cores", "memory_mb", "ip", "os_disk", "cloudinit_storage"):
        if k not in vm:
            raise Fail(f"{path}: [vm].{k} missing")
    if not isinstance(vm["vmid"], int) or isinstance(vm["vmid"], bool) or vm["vmid"] < MIN_VMID:
        raise Fail(f"{path}: [vm].vmid must be a whole number >= {MIN_VMID}, not {vm['vmid']!r}")
    if vm["node"] not in NODES:
        raise Fail(f"{path}: node {vm['node']} not in {NODES}")
    if node and node != vm["node"]:
        if node not in NODES:
            raise Fail(f"--node {node} not in {NODES}")
        if not vm.get("disposable"):
            raise Fail(f"{host} is not disposable: its node is its spec's ({vm['node']}), not --node {node}")
        vm["node"] = node
    if "startup" in vm and not (isinstance(vm["startup"], str) and STARTUP_FORM.fullmatch(vm["startup"])):
        raise Fail(f"{path}: [vm].startup must be order=N[,up=S][,down=S], not {vm['startup']!r}")
    labels = spec.get("runner", {}).get("labels", [])
    if not isinstance(labels, list) or not all(isinstance(l, str) and l for l in labels):
        raise Fail(f"{path}: [runner].labels must be a list of names")
    check_gitlab_runner_spec(path, spec)
    spec["apps_tree"] = host
    rep = spec.get("replica")
    if rep:
        src = rep.get("of", "")
        src_path = REPO / src / "host.toml"
        if src == host or not src_path.is_file():
            raise Fail(f"{path}: [replica] of = {src!r} is not another host with a spec")
        src_spec = tomllib.loads(src_path.read_text())
        unknown_keys = set(rep) - set(REPLICA_KEYS)
        if unknown_keys:
            raise Fail(f"{path}: unknown [replica] keys: {sorted(unknown_keys)} (known: {', '.join(REPLICA_KEYS)})")
        if spec.get("runner", {}).get("enabled") or spec.get("gitlab_runner"):
            raise Fail(f"{path}: a replica has no [runner] or [gitlab_runner]: its egress is blocked")
        if not isinstance(rep.get("start_apps", True), bool):
            raise Fail(f"{path}: [replica].start_apps must be true or false")
        excl = set(rep.get("exclude_secrets", []))
        unknown = excl - {s["var"] for s in src_spec.get("secret", [])}
        if unknown:
            raise Fail(f"{path}: exclude_secrets not in {src}: {sorted(unknown)}")
        # live_on: where the running copy of a secret file is (the pre-flight compares it there).
        spec["secret"] = [{**s, "live_on": src} for s in src_spec.get("secret", []) if s["var"] not in excl] \
            + spec.get("secret", [])
        spec["app"] = replica_apps(path, rep, src, src_spec.get("app", []))
        check_replica_config(path, rep, spec["app"])
        spec["apps_tree"] = src
        if spec.get("external"):
            raise Fail(f"{path}: a replica has no [[external]] (it must not answer for {src}'s names)")
    for e in spec.get("external", []):
        if "check" in e and not (isinstance(e["check"], str) and e["check"].strip()):
            raise Fail(f"{path}: [[external]] {e.get('name')!r}: check must be a shell command")
        en = e.get("env", [])
        if not isinstance(en, list) or not all(isinstance(n, str) and ENV_NAME.fullmatch(n) for n in en) \
                or len(set(en)) != len(en):
            raise Fail(f"{path}: [[external]] {e.get('name')!r}: env must be a list of distinct environment "
                       f"variable names ({ENV_NAME.pattern})")
    for s in spec.get("secret", []):
        if not s.get("var", "").replace("_", "").isalnum():
            raise Fail(f"{path}: bad secret var {s.get('var')!r}")
    for a in spec.get("app", []):
        check_app_env(path, a)
    check_host_maintenance_spec(path, spec)
    if host not in LEGACY_HOSTS:
        own = REPO / host / "setup"
        if own.is_dir() and any(own.iterdir()):
            raise Fail(f"{REPO / host / 'setup'}: a host has no build scripts of its own; they are in {BUILD_SETUP}/")
        missing = [s for s in spec.get("setup", {}).get("steps", []) if not (REPO / BUILD_SETUP / s).is_file()]
        if missing:
            raise Fail(f"{path}: [setup].steps not in {BUILD_SETUP}/: {missing}")
    return spec


def replica_apps(path: Path, rep: dict, src: str, apps: list[dict]) -> list[dict]:
    """The source's [[app]] list, or only the apps [replica].apps names (in the source's order)."""
    if "apps" not in rep:
        return apps
    names = rep["apps"]
    if not isinstance(names, list) or not names or not all(isinstance(n, str) for n in names):
        raise Fail(f"{path}: [replica].apps must be a list of app names")
    unknown = set(names) - {a["name"] for a in apps}
    if unknown:
        raise Fail(f"{path}: [replica].apps not in {src}: {sorted(unknown)}")
    return [a for a in apps if a["name"] in names]


def check_app_env(path: Path, a: dict) -> None:
    """[[app]] pull_token_env (one environment variable name), start_env (a list of them) and
    restore_timeout (seconds, above 0)."""
    name = a.get("name", "?")
    p = a.get("pull_token_env")
    if p is not None and not (isinstance(p, str) and ENV_NAME.fullmatch(p)):
        raise Fail(f"{path}: [[app]] {name!r}: pull_token_env must be an environment variable name "
                   f"({ENV_NAME.pattern}), not {p!r}")
    se = a.get("start_env", [])
    if not isinstance(se, list) or not all(isinstance(n, str) and ENV_NAME.fullmatch(n) for n in se) \
            or len(set(se)) != len(se):
        raise Fail(f"{path}: [[app]] {name!r}: start_env must be a list of distinct environment variable "
                   f"names ({ENV_NAME.pattern})")
    if p is not None and pull_env_name(name) in se:
        raise Fail(f"{path}: [[app]] {name!r}: start_env names {pull_env_name(name)}, which pull_token_env sets")
    rt = a.get("restore_timeout", RESTORE_TIMEOUT)
    if isinstance(rt, bool) or not isinstance(rt, int) or rt <= 0:
        raise Fail(f"{path}: [[app]] {name!r}: restore_timeout must be a whole number of seconds above 0, not {rt!r}")


def pull_env_name(app: str) -> str:
    """The name an app script reads its registry pull token from (pull_token_env)."""
    return f"{app.upper().replace('-', '_')}_REGISTRY_PULL_TOKEN"


def from_env(name: str, why: str) -> str:
    """A value from build_host.py's own environment, for SSH stdin only; never printed."""
    v = os.environ.get(name, "")
    if not v:
        raise Fail(f"{name} is not in the environment ({why}); run build_host.py through the credentials "
                   f"capability with {name} among its names")
    if "\n" in v or "\r" in v:
        raise Fail(f"{name} holds a line break ({why}); not sent")
    return v


def env_needed(spec: dict, phases: list[str]) -> list[tuple[str, str]]:
    """(name, what needs it) for each value the given phases take from build_host.py's environment:
    apps' pull_token_env (restore, apps, late) and start_env (apps, late; never on a replica), and
    [[external]] env (external)."""
    need = []
    for a in spec.get("app", []):
        if a.get("pull_token_env") and {"restore", "apps", "late"} & set(phases):
            need.append((a["pull_token_env"], f"[[app]] {a['name']} pull_token_env"))
        if not spec.get("replica") and {"apps", "late"} & set(phases):
            need += [(n, f"[[app]] {a['name']} start_env") for n in a.get("start_env", [])]
    if "external" in phases:
        for e in spec.get("external", []):
            need += [(n, f"[[external]] {e['name']} env") for n in e.get("env", [])]
    return need


def preflight_env(spec: dict, phases: list[str], apply: bool) -> None:
    """Before any phase: each value the phases will take from the environment is set (names only,
    never a value), so a build does not stop half-way for a missing one. Dry run: listed only."""
    need = env_needed(spec, phases)
    if not need:
        return
    missing = [n for n, _ in need if not os.environ.get(n)]
    print(f"pre-flight: {len(need)} value(s) from the environment")
    for n, why in need:
        print(f"  {n:44} {'set' if os.environ.get(n) else 'MISSING'}  ({why})")
    if missing and apply:
        raise Fail(f"not in the environment: {', '.join(dict.fromkeys(missing))}; run build_host.py through "
                   f"the credentials capability with those names")


def app_env(spec: dict, a: dict, start: bool) -> list[tuple[str, str]]:
    """(name on the host, value) pairs one app command gets over SSH stdin: the pull token, and for a
    start command on a host that is not a replica, start_env (docstring, App environment)."""
    pairs = []
    if a.get("pull_token_env"):
        pairs.append((pull_env_name(a["name"]),
                      from_env(a["pull_token_env"], f"[[app]] {a['name']} pull_token_env")))
    if start and not spec.get("replica"):
        pairs += [(n, from_env(n, f"[[app]] {a['name']} start_env")) for n in a.get("start_env", [])]
    return pairs


def env_command(pairs: list[tuple[str, str]], command: str) -> tuple[str, str | None]:
    """COMMAND run on the host with each pair's value read from stdin into its name and exported:
    (the command, its stdin). Only names are in the command line; no pairs: COMMAND unchanged."""
    if not pairs:
        return command, None
    names = [n for n, _ in pairs]
    reads = " && ".join(f"IFS= read -r {n}" for n in names)
    inner = f"{reads} && export {' '.join(names)} && {command}"
    return f"bash -c {shlex.quote(inner)}", "".join(v + "\n" for _, v in pairs)


def check_replica_config(path: Path, rep: dict, apps: list[dict]) -> None:
    """[replica.gitea_config] (app.ini section -> {KEY = value}) and [replica].verify (local URLs)."""
    gc = rep.get("gitea_config", {})
    if not isinstance(gc, dict):
        raise Fail(f"{path}: [replica.gitea_config] must be a table of app.ini sections")
    if gc and "gitea" not in {a["name"] for a in apps}:
        raise Fail(f"{path}: [replica.gitea_config] needs the gitea app in the replica")
    for sec, kv in gc.items():
        if not INI_SECTION.fullmatch(sec) or not isinstance(kv, dict) or not kv:
            raise Fail(f"{path}: [replica.gitea_config] section {sec!r} must be a lower-case app.ini "
                       f"section name holding KEY = value pairs")
        for k, v in kv.items():
            if not INI_KEY.fullmatch(k):
                raise Fail(f"{path}: [replica.gitea_config.{sec}] key {k!r} must be upper-case")
            if isinstance(v, bool) or (isinstance(v, int) and not isinstance(v, bool)):
                continue
            if not isinstance(v, str) or not INI_VALUE.fullmatch(v):
                raise Fail(f"{path}: [replica.gitea_config.{sec}] {k}: value must be true/false, a number "
                           f"or plain text ({INI_VALUE.pattern})")
    av = rep.get("app_verify", [])
    with_verify = {a["name"] for a in apps if a.get("verify")}
    if not isinstance(av, list) or not all(isinstance(n, str) for n in av):
        raise Fail(f"{path}: [replica].app_verify must be a list of app names")
    if set(av) - with_verify:
        raise Fail(f"{path}: [replica].app_verify names apps that are not in the replica or have no "
                   f"verify: {sorted(set(av) - with_verify)}")
    urls = rep.get("verify", [])
    if not isinstance(urls, list) or not all(isinstance(u, str) and u.startswith(("http://{ip}:", "http://127.0.0.1:"))
                                             and "{" not in u.replace("{ip}", "") and " " not in u for u in urls):
        raise Fail(f"{path}: [replica].verify must be a list of local URLs \"http://{{ip}}:PORT/...\" "
                   f"or \"http://127.0.0.1:PORT/...\"")


def ini_value(v) -> str:
    return ("true" if v else "false") if isinstance(v, bool) else str(v)


def gitea_env(section: str, key: str) -> str:
    """The environment-to-ini name of an app.ini key (Gitea's cmd/config.go: '.' is _0x2E_)."""
    return f"GITEA__{section.replace('.', '_0x2E_')}__{key}"


def check_gitlab_runner_spec(path: Path, spec: dict) -> None:
    """[gitlab_runner] runners = [{name, scope, tags, executor, and for docker: image, volumes,
    pull_policy}], or no table at all. Values go into a gitlab-runner command line and the API."""
    gr = spec.get("gitlab_runner")
    if gr is None:
        return
    where = f"{path}: [gitlab_runner]"
    if not isinstance(gr, dict) or set(gr) != {"runners"}:
        raise Fail(f"{where} must hold only runners = [...]")
    runners = gr["runners"]
    if not isinstance(runners, list) or not runners or not all(isinstance(r, dict) for r in runners):
        raise Fail(f"{where}.runners must be a non-empty list of tables")
    seen = set()
    for r in runners:
        name = r.get("name")
        if not isinstance(name, str) or not GL_RUNNER_NAME.fullmatch(name):
            raise Fail(f"{where}: runner name must be lower-case letters, digits and dashes, not {name!r}")
        if name in seen:
            raise Fail(f"{where}: runner {name} named twice")
        seen.add(name)
        allowed = {"name", "scope", "tags", "executor"}
        if not isinstance(r.get("scope"), str) or not GL_RUNNER_SCOPE.fullmatch(r["scope"]):
            raise Fail(f"{where}: runner {name}: scope must be group:PATH or project:GROUP/PROJECT, not {r.get('scope')!r}")
        tags = r.get("tags")
        if not isinstance(tags, list) or not tags or not all(isinstance(t, str) and GL_RUNNER_TAG.fullmatch(t) for t in tags) \
                or len(set(tags)) != len(tags):
            raise Fail(f"{where}: runner {name}: tags must be a non-empty list of distinct tag names "
                       f"(a runner without tags would take untagged jobs)")
        if r.get("executor") not in GL_EXECUTORS:
            raise Fail(f"{where}: runner {name}: executor must be one of {GL_EXECUTORS}, not {r.get('executor')!r}")
        if r["executor"] == "docker":
            allowed |= {"image", "volumes", "pull_policy"}
            if not isinstance(r.get("image"), str) or not r["image"] or any(c.isspace() for c in r["image"]):
                raise Fail(f"{where}: runner {name}: a docker runner needs image = \"...\"")
            vols = r.get("volumes", [])
            if not isinstance(vols, list) or not all(isinstance(v, str) and v and not any(c.isspace() for c in v) for v in vols):
                raise Fail(f"{where}: runner {name}: volumes must be a list of HOST:CONTAINER[:MODE] or PATH strings")
            if r.get("pull_policy", "if-not-present") not in GL_PULL_POLICIES:
                raise Fail(f"{where}: runner {name}: pull_policy must be one of {GL_PULL_POLICIES}")
        unknown = set(r) - allowed
        if unknown:
            raise Fail(f"{where}: runner {name}: unknown keys {sorted(unknown)}")


def check_host_maintenance_spec(path: Path, spec: dict) -> None:
    """[host_maintenance] identity, user, known_hosts, optionally self_address (module docstring),
    or no table at all. Checked after a replica's secrets are merged: the identity is one of the
    host's [[secret]]s."""
    hm = spec.get("host_maintenance")
    if hm is None:
        return
    where = f"{path}: [host_maintenance]"
    want = {"identity", "user", "known_hosts"}
    if not isinstance(hm, dict) or not want <= set(hm) <= want | {"self_address"}:
        raise Fail(f"{where} must hold identity, user and known_hosts, optionally self_address, and nothing else")
    ident = hm["identity"]
    if not isinstance(ident, str) or not HM_PATH.fullmatch(ident) or ".." in ident.split("/"):
        raise Fail(f"{where}: identity must be an absolute path, not {ident!r}")
    if ident.startswith(DATA_ROOT):
        raise Fail(f"{where}: identity under {DATA_ROOT} is installed after the setup phase; keep it outside")
    owners = [s for s in spec.get("secret", []) if s.get("path") == ident]
    if len(owners) != 1:
        raise Fail(f"{where}: identity must be the path of one [[secret]] (the private key comes from GitLab)")
    if str(owners[0].get("mode", "600")) != "600":
        raise Fail(f"{where}: the identity's [[secret]] must have mode 600 (ssh refuses a wider one)")
    owner = owners[0].get("owner", "docker:docker")
    if not (isinstance(owner, str) and owner.count(":") == 1 and all(HM_NAME.fullmatch(x) for x in owner.split(":"))):
        raise Fail(f"{where}: the identity's [[secret]] owner must be USER:GROUP, not {owner!r}")
    if not isinstance(hm["user"], str) or not HM_NAME.fullmatch(hm["user"]):
        raise Fail(f"{where}: user must be a user name, not {hm['user']!r}")
    pins = hm["known_hosts"]
    if not isinstance(pins, list) or not pins or not all(isinstance(p, str) and HM_PIN.fullmatch(p) for p in pins):
        raise Fail(f"{where}: known_hosts must be a non-empty list of \"ADDRESS ssh-ed25519 KEY\" lines")
    addrs = [p.split()[0] for p in pins]
    if len(set(addrs)) != len(addrs):
        raise Fail(f"{where}: known_hosts pins an address twice")
    if "self_address" in hm:
        own = hm["self_address"]
        if own != ip_only(spec):
            raise Fail(f"{where}: self_address must be this host's own [vm] ip {ip_only(spec)}, not {own!r}")
        if own in addrs:
            raise Fail(f"{where}: self_address {own} is also pinned in known_hosts; the host's own key "
                       "is read on the host at build time, never pinned")


def hm_owner(spec: dict) -> str:
    """The owner of the host-maintenance key set: its identity's [[secret]] owner."""
    ident = spec["host_maintenance"]["identity"]
    return next(s.get("owner", "docker:docker") for s in spec["secret"] if s.get("path") == ident)


def legacy(spec: dict) -> bool:
    return spec["host"] in LEGACY_HOSTS


def app_script(tree: str, app: str) -> str:
    """An app's script under ~/scripts/<tree>/apps (tree: the host, or a replica's source)."""
    return f"~/scripts/{tree}/apps/{app}/{app}.sh"


def starts_apps(spec: dict) -> bool:
    return spec.get("replica", {}).get("start_apps", True)


def ip_only(spec: dict) -> str:
    return spec["vm"]["ip"].split("/")[0]


# ---------------------------------------------------------------- Proxmox

def cluster_vms() -> list[dict]:
    r = ssh(root(NODES[0]), "pvesh get /cluster/resources --type vm --output-format json")
    return json.loads(r.stdout)


def find_vm(vmid: int) -> dict | None:
    return next((v for v in cluster_vms() if v.get("vmid") == vmid), None)


def phase_vm(spec: dict, apply: bool, recreate: bool, confirm: str | None) -> None:
    vm, host = spec["vm"], spec["host"]
    node, vmid = vm["node"], vm["vmid"]
    live = find_vm(vmid)
    if live:
        if live.get("name") != host:
            raise Fail(f"VMID {vmid} is {live.get('name')} on {live.get('node')}, not {host}; refusing")
        if not recreate:
            print(f"VM {vmid} ({host}) exists on {live['node']} ({live['status']}); skipping (use --recreate)")
            return
        if not vm.get("disposable") and confirm != host:
            raise Fail(f"{host} is not disposable: --recreate needs --confirm {host} (and the operator's approval)")
        destroy_vm(spec, apply, live["node"])
    elif subprocess.run(["ping", "-c", "2", "-t", "3", ip_only(spec)], capture_output=True).returncode == 0:
        raise Fail(f"{ip_only(spec)} answers ping but VMID {vmid} does not exist; refusing to create a duplicate")

    d = vm["os_disk"]
    q = f"qm set {vmid}"
    cmds = [
        f"qm create {vmid} --name {host} --sockets {vm['sockets']} --cores {vm['cores']} "
        f"--memory {vm['memory_mb']} --ostype l26 --scsihw virtio-scsi-pci --vga std "
        f"--net0 virtio,bridge={BRIDGE},firewall=1,tag={VLAN} --onboot 1 "
        f"--agent 1,fstrim_cloned_disks=1" + (f" --startup {vm['startup']}" if vm.get("startup") else ""),
        f"{q} --scsi0 {d['storage']}:0,import-from={IMAGE},discard=on,ssd=1",
        # import-from skips the image's zero blocks (qemu zeroinit: lvmthin claims sparseinit), but the
        # nodes' thin pools do not zero new chunks, so those blocks keep a deleted volume's bytes; on
        # 2026-10-17 they broke test01's GPT and it never found its root. Rewrite with the zeros
        # (-S 0: fully allocated) and stop unless the disk now reads as the image.
        f"V=$(qm config {vmid} | sed -n 's/^scsi0: \\([^,]*\\),.*/\\1/p') && P=$(pvesm path \"$V\") && "
        f"qemu-img convert -n -S 0 -f qcow2 -O raw {IMAGE} \"$P\" && qemu-img compare -f qcow2 -F raw {IMAGE} \"$P\"",
        f"qm resize {vmid} scsi0 {d['size']}",
        f"{q} --scsi1 {vm['cloudinit_storage']}:cloudinit",
        f"{q} --boot order=scsi0",
    ]
    if vm.get("data_disk"):
        dd = vm["data_disk"]
        cmds.append(f"{q} --scsi2 {dd['storage']}:{dd['size'].rstrip('G')},discard=on,ssd=1")
    cmds += [
        f"{q} --ciuser docker --sshkeys /tmp/{host}-docker_rsa.pub",
        f"{q} --ipconfig0 ip={vm['ip']},gw={GATEWAY} --nameserver '{NAMESERVERS}' --searchdomain {SEARCHDOMAIN}",
        f"{q} --cicustom vendor=local:snippets/{host}-vendor.yml",
        f"rm -f /tmp/{host}-docker_rsa.pub",
        f"qm start {vmid}",
    ]
    print(f"create VM {vmid} {host} on {node}:")
    for c in cmds:
        print(f"  {c}")
    if not apply:
        return
    run(["scp", "-q", "-o", "BatchMode=yes", str(REPO / "scripts/cloud-init-vendor.yml"),
         f"{root(node)}:/var/lib/vz/snippets/{host}-vendor.yml"])
    run(["scp", "-q", "-o", "BatchMode=yes", str(SSH_KEY_PUB), f"{root(node)}:/tmp/{host}-docker_rsa.pub"])
    for c in cmds:
        ssh(root(node), c, timeout=1800)
    # A recreated VM has a new host key: drop the old one for its name and address only.
    for name in (host, ip_only(spec), f"{host}.{SEARCHDOMAIN}"):
        run(["ssh-keygen", "-R", name], check=False)
    wait_ssh(host)
    print("waiting for cloud-init")
    ssh(host, "cloud-init status --wait >/dev/null", timeout=1800, check=False)
    r = ssh(host, "cloud-init status; id docker; test -f /var/lib/cloud/instance/asyla-vendor-done", check=False)
    print(r.stdout.strip())
    if r.returncode != 0 or "status: done" not in r.stdout:
        raise Fail(f"cloud-init on {host} did not finish cleanly (see /var/log/cloud-init-output.log there)")


def wait_ssh(host: str, minutes: int = 15) -> None:
    deadline = time.time() + minutes * 60
    opts = ["-o", "StrictHostKeyChecking=accept-new"]
    while time.time() < deadline:
        argv = ssh_argv(host)
        r = subprocess.run(argv[:-1] + opts + [argv[-1], "true"], capture_output=True, text=True)
        if r.returncode == 0:
            print(f"ssh {host}: up")
            return
        time.sleep(15)
    raise Fail(f"ssh {host} not reachable after {minutes} min")


def destroy_vm(spec: dict, apply: bool, node: str) -> None:
    vmid, host = spec["vm"]["vmid"], spec["host"]
    print(f"destroy VM {vmid} ({host}) on {node} with its disks")
    if spec["runner"].get("enabled") if "runner" in spec else False:
        delete_runner_entry(host, apply)
    delete_gitlab_runner_entries(spec, apply)
    if apply:
        ssh(root(node), f"qm stop {vmid} --skiplock 1 >/dev/null 2>&1 || true; qm destroy {vmid} --purge 1")


# ---------------------------------------------------------------- bootstrap, disk, setup

def master_file(relpath: str) -> str:
    """A file as GitLab master has it (what the host will run), via the local clone's origin."""
    run(["git", "-C", str(REPO), "fetch", "-q", "origin", "master"])
    return run(["git", "-C", str(REPO), "show", f"origin/master:{relpath}"]).stdout


# The credential helper of TOKEN_FILE_HOSTS' update_scripts.sh: reads DEPLOY_ENV, never puts the token in argv.
GIT_DEPLOY_AUTH = ("GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= "
                   "GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!f() { test \"$1\" = get || return 0; "
                   f". {DEPLOY_ENV}; echo username=$ASYLA_HOSTS_DEPLOY_USER; echo password=$ASYLA_HOSTS_DEPLOY_TOKEN; }}; f'")


def install_token(host: str, apply: bool) -> None:
    """Install DEPLOY_ENV alone (root 0600), then prove the host can read GitLab master with it."""
    user, token = need("ASYLA_HOSTS_DEPLOY_USER"), need("ASYLA_HOSTS_DEPLOY_TOKEN")
    print(f"install {DEPLOY_ENV} on {host} (root 0600; value ...{token[-4:]}), then git ls-remote GitLab master")
    if not apply:
        return
    body = f"ASYLA_HOSTS_DEPLOY_USER={user}\nASYLA_HOSTS_DEPLOY_TOKEN={token}\n"
    ssh(host, f"sudo install -d -m 755 /etc/asyla && sudo sh -c 'umask 077; cat > {DEPLOY_ENV}.tmp' && "
              f"sudo chown root:root {DEPLOY_ENV}.tmp && sudo chmod 600 {DEPLOY_ENV}.tmp && "
              f"sudo mv {DEPLOY_ENV}.tmp {DEPLOY_ENV}", stdin=body)
    check_token(host)


def deploy_credential() -> str:
    """The deploy token as update_scripts.sh reads it from stdin (git credential lines)."""
    return f"username={need('ASYLA_HOSTS_DEPLOY_USER')}\npassword={need('ASYLA_HOSTS_DEPLOY_TOKEN')}\n"


# update_scripts.sh's credential block in short: the two lines from stdin into this shell's
# environment, and a helper that echoes them (single-quoted: expanded when git calls it).
GIT_STDIN_AUTH = ("IFS= read -r u; IFS= read -r p; export U=\"${u#username=}\" P=\"${p#password=}\"; "
                  "export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= "
                  "GIT_CONFIG_KEY_1=credential.helper; "
                  "export GIT_CONFIG_VALUE_1='!f() { test \"$1\" = get || return 0; echo \"username=$U\"; echo \"password=$P\"; }; f'")


def check_stdin_read(host: str) -> str:
    """The master SHA the host reads from GitLab with the deploy token handed on stdin (Fail if it cannot)."""
    r = ssh(host, f"bash -c {shlex.quote(GIT_STDIN_AUTH + f'; git ls-remote https://gitlab.com/{GITLAB_PROJECT}.git refs/heads/master')}",
            stdin=deploy_credential(), check=False)
    sha = r.stdout.split()[0] if r.returncode == 0 and r.stdout.split() else ""
    if not sha:
        raise Fail(f"{host}: cannot read GitLab with the deploy token on stdin (exit {r.returncode})")
    print(f"{host}: reads GitLab master {sha[:12]} with the deploy token on stdin (none stored)")
    return sha


def remove_token_file(host: str, apply: bool) -> None:
    """A host outside TOKEN_FILE_HOSTS keeps no deploy token: remove DEPLOY_ENV if an old build left it."""
    print(f"remove {DEPLOY_ENV} on {host} if present (no token file outside {', '.join(TOKEN_FILE_HOSTS)})")
    if apply:
        ssh(host, f"sudo rm -f {DEPLOY_ENV} && ! sudo test -e {DEPLOY_ENV}")


def token_file_absent(host: str) -> bool:
    return ssh(host, f"sudo test -e {DEPLOY_ENV}", check=False).returncode == 1


def check_token(host: str) -> str:
    """The master SHA the host reads from GitLab with its deploy token (Fail if it cannot)."""
    r = ssh(host, f"sudo stat -c '%U:%G %a' {DEPLOY_ENV} && sudo env {GIT_DEPLOY_AUTH} "
                  f"git ls-remote https://gitlab.com/{GITLAB_PROJECT}.git refs/heads/master", check=False)
    lines = r.stdout.split()
    if r.returncode != 0 or len(lines) < 2 or lines[0] != "root:root" or lines[1] != "600":
        raise Fail(f"{host}: {DEPLOY_ENV} missing, wrong owner/mode, or cannot read GitLab (exit {r.returncode})")
    sha = lines[2] if len(lines) > 2 else ""
    print(f"{host}: {DEPLOY_ENV} root:root 600; GitLab master {sha[:12]}")
    return sha


def build_only_paths(spec: dict) -> list[str]:
    """The tracked paths a new host's updater does not keep: each installed tree's setup/ and
    host.toml, and docker/setup/ (the legacy hosts' copy of the base build scripts)."""
    return [p for t in sorted({spec["host"], spec["apps_tree"]}) for p in (f"{t}/setup", f"{t}/host.toml")] + ["docker/setup"]


def scripts_drift(spec: dict) -> tuple[str, list[str]]:
    """GitLab master's SHA and the tracked HOST/, replica source and docker/ paths whose ~/scripts copy differs."""
    host = spec["host"]
    trees = sorted({host, spec["apps_tree"], "docker"})
    run(["git", "-C", str(REPO), "fetch", "-q", "origin", "master"])
    sha = run(["git", "-C", str(REPO), "rev-parse", "origin/master"]).stdout.strip()
    want = {}
    skip = () if legacy(spec) else build_only_paths(spec)
    for line in run(["git", "-C", str(REPO), "ls-tree", "-r", "origin/master", "--", *trees]).stdout.splitlines():
        meta, _, path = line.partition("\t")
        if meta.split()[1] == "blob" and not any(path == s or path.startswith(s + "/") for s in skip):
            want[path] = meta.split()[2]
    paths = sorted(want)
    # A symlink is hashed as git stores it: the link text, not the file it points to.
    r = ssh(host, "cd ~/scripts && while IFS= read -r f; do if [ -L \"$f\" ]; then printf %s \"$(readlink \"$f\")\" "
                  "| git hash-object --stdin; elif [ -f \"$f\" ]; then git hash-object -- \"$f\"; "
                  "else echo missing; fi; done", stdin="\n".join(paths) + "\n", check=False)
    have = r.stdout.split()
    if r.returncode != 0 or len(have) != len(paths):
        return sha, [f"cannot hash ~/scripts on {host} (exit {r.returncode})"]
    return sha, [p for p, h in zip(paths, have) if want[p] != h]


def phase_bootstrap(spec: dict, apply: bool) -> None:
    host = spec["host"]
    if host in TOKEN_FILE_HOSTS:
        install_token(host, apply)
        print(f"then {host}/update_scripts.sh from GitLab master")
    else:
        remove_token_file(host, apply)
        print(f"then {host}/update_scripts.sh from GitLab master, the deploy token on its stdin (no file)")
    script = master_file(f"{host}/update_scripts.sh")
    if not apply:
        return
    ssh(host, "sudo apt-get install -y -qq git curl rsync >/dev/null", timeout=900)
    if host in TOKEN_FILE_HOSTS:
        ssh(host, "cat > /tmp/update_scripts.sh && sudo bash /tmp/update_scripts.sh; rc=$?; rm -f /tmp/update_scripts.sh; exit $rc",
            stdin=script, stream=True)
        return
    # The script goes in the command (base64, no secret in it), so stdin carries only the credential.
    b64 = base64.b64encode(script.encode()).decode()
    ssh(host, f"echo {b64} | base64 -d > /tmp/update_scripts.sh && sudo bash /tmp/update_scripts.sh; rc=$?; "
              "rm -f /tmp/update_scripts.sh; exit $rc", stdin=deploy_credential(), stream=True)


def bundle(paths: list[str], ref: str = "origin/master") -> str:
    """base64 of a tar.gz of PATHS as REF has them (origin/master: what GitLab holds, fetched first)."""
    if ref == "origin/master":
        run(["git", "-C", str(REPO), "fetch", "-q", "origin", "master"])
    r = subprocess.run(["git", "-C", str(REPO), "archive", "--format=tar.gz", ref, "--", *paths],
                       capture_output=True, timeout=120)
    if r.returncode != 0:
        raise Fail(f"git archive {ref} {' '.join(paths)}: exit {r.returncode}")
    return base64.b64encode(r.stdout).decode()


BUILD_DIR_GLOB = "asyla-build.*"   # verify: none of these may be left on a host


def bundle_script(b64: str, command: str, base: str) -> str:
    """A bash script that unpacks the bundle into a new folder under BASE, runs COMMAND there ($B
    is the folder) and removes the folder however COMMAND ends, keeping its exit status."""
    return (f"set -e\nB=$(mktemp -d {base}/{BUILD_DIR_GLOB[:-1]}XXXXXX)\ntrap 'rm -rf \"$B\"' EXIT\n"
            f"printf %s '{b64}' | base64 -d | tar -xzf - -C \"$B\"\n{command}\n")


def build_run(host: str, paths: list[str], command: str, as_root: bool, stdin: str | None = None) -> None:
    """Run COMMAND on HOST from a bundle of PATHS (see bundle_script): as root under /root, or as
    the guest user under /tmp. The bundle travels in the command, so stdin stays free."""
    script = bundle_script(bundle(paths), command, "/root" if as_root else "/tmp")
    ssh(host, f"{'sudo ' if as_root else ''}bash -c {shlex.quote(script)}", stdin=stdin, stream=True, timeout=3600)


def build_step(host: str, script: str, args: str = "") -> None:
    """build/setup/SCRIPT as root, with HOST_SPEC naming the host's own host.toml."""
    build_run(host, ["build", f"{host}/host.toml"],
              f'HOST_SPEC="$B/{host}/host.toml" bash "$B/{BUILD_SETUP}/{script}" {args}'.rstrip(), as_root=True)


def phase_disk(spec: dict, apply: bool) -> None:
    host = spec["host"]
    dd = spec["vm"].get("data_disk")
    owner = (dd or {}).get("owner", "docker:asyla")
    if not dd:
        print("no data disk in spec; /mnt/docker stays on the root disk")
        if apply:
            ssh(host, f"sudo install -d -o {owner.split(':')[0]} -g {owner.split(':')[1]} /mnt/docker")
        return
    print(f"data disk scsi2 -> /mnt/docker ({owner})")
    if apply:
        if legacy(spec):
            ssh(host, f"sudo ~/scripts/docker/setup/data_disk.sh scsi2 /mnt/docker {owner}", stream=True)
        else:
            build_step(host, "data_disk.sh", f"scsi2 /mnt/docker {shlex.quote(owner)}")


def select_steps(spec: dict, steps: list[str]) -> None:
    """--step: keep only these setup steps in SPEC. One step on a running host (d03's node exporter,
    2026-10-27): the other steps are not re-run (docker.sh stops on a host with containers), nor the
    host-maintenance key set unless it is named."""
    known = spec.get("setup", {}).get("steps", []) + ([HM_SCRIPT] if spec.get("host_maintenance") else [])
    unknown = sorted(set(steps) - set(known))
    if unknown:
        raise Fail(f"--step {', '.join(unknown)}: not in {spec['host']}'s [setup].steps")
    spec["setup"]["steps"] = [s for s in spec["setup"]["steps"] if s in steps]
    if HM_SCRIPT not in steps:
        spec.pop("host_maintenance", None)


def phase_setup(spec: dict, apply: bool) -> None:
    host = spec["host"]
    for s in spec.get("setup", {}).get("steps", []):
        print(f"setup: {s}" + ("" if legacy(spec) else f" ({BUILD_SETUP}/, sent from GitLab master)"))
        if apply:
            if legacy(spec):
                ssh(host, f"sudo ~/scripts/{host}/setup/{s}", stream=True, timeout=3600)
            else:
                build_step(host, s)
    hm = spec.get("host_maintenance")
    if hm:
        print(f"setup: {HM_SCRIPT} ({BUILD_SETUP}/, sent from GitLab master): {hm['identity']}.pub, "
              f"known_hosts from {len(hm['known_hosts'])} pin(s)"
              + (f" and {host}'s own key ({HM_HOST_KEY}) as {hm['self_address']}" if hm.get("self_address") else "")
              + f" (each checked by ssh-keyscan from {host}), {hm['user']}'s authorized_keys")
        if apply:
            build_step(host, HM_SCRIPT)


# ---------------------------------------------------------------- secrets

def var_path(key: str) -> str:
    return f"/projects/{urllib.parse.quote(GITLAB_PROJECT, safe='')}/variables/{key}"


def gitlab_secret(key: str) -> str | None:
    code, body = gitlab("GET", var_path(key))
    if code == 404:
        return None
    if code != 200:
        raise Fail(f"GitLab variable {key}: HTTP {code}")
    return body["value"]


def host_secret(host: str, path: str) -> str | None:
    r = ssh(host, f"sudo test -f {shlex.quote(path)} && sudo cat {shlex.quote(path)}", check=False)
    return r.stdout if r.returncode == 0 else None


def digest(v: str | None) -> str:
    return hashlib.sha256(v.encode()).hexdigest()[:12] if v is not None else "-"


DOTENV_LINE = re.compile(r"(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)")


def dotenv_keys(v: str | None) -> dict[str, str] | None:
    """A secret's KEY=VALUE lines (blank lines and # comments ignored; a repeated key, its last
    value), or None when it is missing, holds no such line, or holds any other line."""
    if v is None:
        return None
    keys = {}
    for line in v.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = DOTENV_LINE.fullmatch(line)
        if not m:
            return None
        keys[m.group(1)] = m.group(2)
    return keys or None


def key_states(g: dict[str, str], h: dict[str, str]) -> list[tuple[str, str]]:
    """(key, state) per key of either side, sorted: same, DIFFERS, only in GitLab, only on host.
    The state only: never a value, a length or a per-key digest."""
    return [(k, "only on host" if k not in g else "only in GitLab" if k not in h
             else "same" if g[k] == h[k] else "DIFFERS") for k in sorted(set(g) | set(h))]


def in_app_data(s: dict) -> bool:
    return s["path"].startswith(DATA_ROOT)


def secrets_cmd(spec: dict, action: str, apply: bool, only: list[str], data: bool | None = None,
                keys: bool = False) -> int:
    """data: None = every secret, False = those outside DATA_ROOT, True = those under it.
    keys (check only): under the line of a secret whose GitLab and host values both parse as
    dotenv, each key's state (key_states); never a value."""
    host, bad = spec["host"], 0
    unknown = sorted(set(only) - {s["var"] for s in spec.get("secret", [])})
    if unknown:     # a mistyped VAR used to match nothing and exit 0
        raise Fail(f"{host}: not a [[secret]] of its spec: {', '.join(unknown)}")
    items = [s for s in spec.get("secret", []) if (not only or s["var"] in only)
             and (data is None or in_app_data(s) == data)]
    for s in items:
        key, path = s["var"], s["path"]
        if action == "check":
            g, h = gitlab_secret(key), host_secret(host, path)
            state = secret_state(g, h)
            bad += state != "in sync"
            print(f"  {key:44} {state:18} gitlab {digest(g)} host {digest(h)}  {path}")
            gk, hk = (dotenv_keys(g), dotenv_keys(h)) if keys else (None, None)
            if gk is not None and hk is not None:
                rows = key_states(gk, hk)
                for k, st in rows:
                    print(f"    {k:42} {st}")
                if state == "DIFFERS" and all(st == "same" for _, st in rows):
                    print("    every key the same: the files differ only in comments, blank lines, order or spacing")
        elif action == "push":
            h = host_secret(host, path)
            if h is None:
                print(f"  {key}: not on {host}; skipped")
                bad += 1
                continue
            g = gitlab_secret(key)
            if g == h:
                print(f"  {key}: in sync")
                continue
            print(f"  {key}: {'update' if g is not None else 'create'} from {host}:{path} ({len(h)} bytes)")
            if apply:
                body = {"value": h, "variable_type": "file", "protected": True, "masked": False, "raw": True}
                if g is None:
                    code, _ = gitlab("POST", var_path("").rstrip("/"), {"key": key, **body})
                else:
                    code, _ = gitlab("PUT", var_path(key), body)
                if code not in (200, 201):
                    raise Fail(f"GitLab variable {key}: HTTP {code}")
        elif action == "install":
            g = gitlab_secret(key)
            if g is None:
                print(f"  {key}: not in GitLab; cannot install {path}")
                bad += 1
                continue
            owner, mode = s.get("owner", "docker:docker"), s.get("mode", "600")
            print(f"  {key} -> {path} ({owner} {mode})")
            if apply:
                p = shlex.quote(path)
                o_user = owner.split(":")[0]
                ssh(host, f"sudo install -d -o {o_user} -g {owner.split(':')[1]} \"$(dirname {p})\" && "
                          f"sudo sh -c 'umask 077; cat > {p}.tmp' && sudo chown {owner} {p}.tmp && "
                          f"sudo chmod {mode} {p}.tmp && sudo mv {p}.tmp {p}", stdin=g)
    return 1 if bad and action != "install" else (1 if bad else 0)


def secret_state(g: str | None, h: str | None) -> str:
    if g is not None and h is not None:
        return "in sync" if g == h else "DIFFERS"
    return "MISSING in GitLab" if h is not None else "MISSING on host" if g is not None else "MISSING everywhere"


def preflight_secrets(spec: dict, apply: bool) -> None:
    """Before a build that may replace a host: each [[secret]] file where it is live (the host, or
    a replica's source) against its GitLab variable, by hash. A file that differs from GitLab, or
    that GitLab does not have, stops the build: the rebuilt host would get another value than
    the one in use, or none. A file missing on the host is installed by the build. Reads the
    secret files (sudo cat over SSH) only with --apply; prints hashes, never a value."""
    host = spec["host"]
    by_host: dict[str, list[dict]] = {}
    for s in spec.get("secret", []):
        by_host.setdefault(s.get("live_on", host), []).append(s)
    bad = []
    for where, items in by_host.items():
        print(f"pre-flight: {len(items)} secret file(s) on {where} against GitLab, by hash")
        if not apply:
            continue
        if ssh(where, "true", check=False, timeout=30).returncode != 0:
            if where != host:
                raise Fail(f"{where} does not answer: its secret files cannot be compared with GitLab")
            print(f"  {where} does not answer (a first build): nothing to compare")
            continue
        for s in items:
            g, h = gitlab_secret(s["var"]), host_secret(where, s["path"])
            state = secret_state(g, h)
            print(f"  {s['var']:44} {state:18} gitlab {digest(g)} host {digest(h)}  {s['path']}")
            if state not in ("in sync", "MISSING on host"):
                bad.append(s["var"])
    if bad:
        raise Fail(f"pre-flight: {', '.join(bad)}: the host's file and GitLab disagree; settle it first "
                   f"(`secrets check`, then `secrets push` once the host's file is known to be the right one)")


def secret_copy(spec: dict, var: str, src: str, apply: bool) -> int:
    """Create the spec's secret VAR in GitLab with the value of another variable, for a secret
    renamed with its host (D04_HELLO_ENV to TEST01_HELLO_ENV). Never overwrites: a VAR that
    exists with another value is refused. The source is left as it is."""
    if var not in {s["var"] for s in spec.get("secret", [])}:
        raise Fail(f"{spec['host']}: not a [[secret]] of its spec: {var}")
    s, g = gitlab_secret(src), gitlab_secret(var)
    if s is None:
        raise Fail(f"GitLab variable {src} does not exist")
    if g is not None:
        if g != s:
            raise Fail(f"GitLab variable {var} exists with another value ({digest(g)} vs {src} {digest(s)}); not overwritten")
        print(f"  {var}: in sync with {src} ({digest(s)})")
        return 0
    print(f"  {var}: create from {src} ({len(s)} bytes, {digest(s)})")
    if apply:
        code, _ = gitlab("POST", var_path("").rstrip("/"), {"key": var, "value": s, "variable_type": "file",
                                                             "protected": True, "masked": False, "raw": True})
        if code not in (200, 201):
            raise Fail(f"GitLab variable {var}: HTTP {code}")
    return 0


# ---------------------------------------------------------------- apps, external, runner

class NotInstalled(Fail):
    """An app's script is not on the host (yet)."""


def app_has(spec: dict, app: str, switch: str) -> bool:
    """Whether the host's APP.sh has SWITCH. grep exits 1 for no match and 2 when it cannot read
    the file: a missing script raises NotInstalled, any other status (ssh's 255) Fail, so neither
    passes for "no such switch"."""
    r = ssh(spec["host"], f"grep -qE '^[[:space:]]+([a-z_|-]+\\|)?{switch}(\\|[a-z_|-]+)?\\)' "
                          f"{app_script(spec['apps_tree'], app)}", check=False)
    if r.returncode in (0, 1):
        return r.returncode == 0
    if r.returncode == 2:
        raise NotInstalled(f"{app}.sh not installed yet")
    raise Fail(f"{app}.sh on {spec['host']} cannot be read (exit {r.returncode})")


def restore_check(spec: dict, app: str) -> tuple[bool, str]:
    """verify's restore line for one app: (passes, detail). A missing script fails with its reason."""
    try:
        has = app_has(spec, app, "restore")
    except Fail as e:
        return False, str(e)
    return has, "" if has else "no restore switch"


def phase_restore(spec: dict, apply: bool) -> None:
    host = spec["host"]
    for a in spec.get("app", []):
        name = a["name"]
        if a.get("restore") is False:
            print(f"restore {name}: not applicable (spec)")
            continue
        try:
            has = app_has(spec, name, "restore")
        except Fail as e:   # the script missing or unreadable: never a restore skipped
            if apply:
                raise Fail(f"restore {name}: {e}; stopped before any app starts")
            print(f"restore {name}: {e}")
            continue
        if not has:
            print(f"restore {name}: GAP - {name}.sh has no restore")
            continue
        limit = a.get("restore_timeout", RESTORE_TIMEOUT)
        print(f"restore {name} (skipped when its data dir is not empty; any other failure stops the build; "
              f"at most {limit} s)")
        if a.get("pull_token_env"):
            print(f"  first `{name}.sh images` with {a['pull_token_env']} over SSH stdin (missing images pulled)")
        if apply and a.get("pull_token_env"):
            cmd, stdin = env_command(app_env(spec, a, start=False),
                                     f"{app_script(spec['apps_tree'], name)} images >/dev/null")
            r = ssh(host, cmd, stdin=stdin, check=False, stream=True, timeout=1800)
            if r.returncode != 0:
                raise Fail(f"restore {name}: pulling its images failed (exit {r.returncode}); stopped before any app starts")
        if apply:
            r = ssh(host, restore_command(app_script(spec['apps_tree'], name)), check=False, stream=True, timeout=limit)
            if r.returncode == RESTORE_SKIPPED:
                print(f"  restore {name}: skipped, its data dir is not empty (data present: a re-run)")
            elif r.returncode != 0:
                raise Fail(f"restore {name}: exit {r.returncode} (no backup, a backup not OK, or the copy failed; "
                           f"its output is above); stopped before any app starts")
    print(f"secrets under {DATA_ROOT} (after the data, so a restore finds its data dir empty):")
    if secrets_cmd(spec, "install", apply, [], data=True):
        raise Fail("a secret is missing in GitLab")


def restore_command(script: str) -> str:
    """`SCRIPT restore` on the host, its output shown as it comes and kept in a temp file: exits
    RESTORE_SKIPPED when the restore refused only because the data dir is not empty (its output
    holds RESTORE_NOT_EMPTY), else the restore's own status, a RESTORE_SKIPPED of its own made 1
    so that nothing else can pass for a skip."""
    inner = (f'L=$(mktemp) || exit 1; {script} restore 2>&1 | tee "$L"; rc=${{PIPESTATUS[0]}}; '
             f'[ "$rc" -ne {RESTORE_SKIPPED} ] || rc=1; '
             f'if [ "$rc" -ne 0 ] && grep -qF {shlex.quote(RESTORE_NOT_EMPTY)} "$L"; then rc={RESTORE_SKIPPED}; fi; '
             f'rm -f "$L"; exit "$rc"')
    return f"bash -c {shlex.quote(inner)}"


def apps_in(spec: dict, late: bool) -> list[dict]:
    """The apps of one start phase: `apps` (before the externals) or `late` (after them)."""
    return [a for a in spec.get("app", []) if bool(a.get("after_external")) == late]


def replica_images(spec: dict, apply: bool) -> list[str]:
    """Pull the images of the replica's started apps that are missing (the last time it can: its
    egress is blocked next) and return their names."""
    if not starts_apps(spec):
        return []
    images = []
    for a in spec.get("app", []):
        if not a.get("start", ["up"]):
            continue
        print(f"images of {a['name']}: pulled when missing, before the egress block")
        if not apply:
            continue
        d = f"~/scripts/{spec['apps_tree']}/apps/{a['name']}"
        try:
            own = app_has(spec, a["name"], "images")
        except NotInstalled:
            own = False
        if own:   # the app's own list (d06's ticketing): its pull token over stdin, its replica mode
            cmd, stdin = env_command(app_env(spec, a, start=False), f"{app_script(spec['apps_tree'], a['name'])} images")
            r = ssh(spec["host"], cmd, stdin=stdin, timeout=1800)
        else:
            r = ssh(spec["host"], f"set -e; cd {d}; [ -f compose.yml ] || exit 0; {COMPOSE_ENV}; "
                                  "imgs=$(docker compose -f compose.yml config --images); for i in $imgs; do "
                                  "docker image inspect \"$i\" >/dev/null 2>&1 || docker pull -q \"$i\" >/dev/null; "
                                  "echo \"$i\"; done", timeout=1800)
        images += [i for i in r.stdout.split() if i not in images]
    return images


def egress_checks(spec: dict, images: list[str] = (), containers: list[str] = ()) -> list[tuple[str, bool, str]]:
    """(label, ok, detail) for the replica's egress block: the table and its unit, then no probe
    URL from the host, from a container of each image, or from inside each running container.
    A probe that cannot run (no curl, wget or python3: 99; docker's own errors: 125 to 127) is no proof."""
    host, out = spec["host"], []
    r = ssh(host, f"sudo nft list table {REPLICA_EGRESS_TABLE} >/dev/null && systemctl is-enabled {REPLICA_EGRESS_UNIT}",
            check=False)
    out.append((f"egress block: nft table {REPLICA_EGRESS_TABLE}, {REPLICA_EGRESS_UNIT} enabled",
                r.returncode == 0, r.stdout.strip()))
    for url in EGRESS_PROBES:
        r = ssh(host, f"curl -s -o /dev/null -m 5 {url}", check=False)
        out.append((f"{host} cannot reach {url}", r.returncode not in (0, 127), f"curl exit {r.returncode}"))
    probe = shlex.quote(EGRESS_PROBE_SH)
    proved, no_shell = None, []   # proved: an image whose probe ran and was blocked on the default bridge
    for img in images:
        r = ssh(host, f"docker run --rm --entrypoint sh {shlex.quote(img)} -c {probe} {EGRESS_PROBES[0]}", check=False)
        if r.returncode == NO_SHELL:
            no_shell.append(img)
            continue
        ok = r.returncode not in (0, 99, 125, 126, 127)
        proved = proved or (img if ok else None)
        out.append((f"a container of {img} cannot reach {EGRESS_PROBES[0]}", ok, f"exit {r.returncode}"))
    # An image with no shell (vikunja's) cannot run the probe. `docker run --rm IMG` puts every
    # image on the same default bridge, so another image's blocked probe is that path's proof; with
    # none, there is no proof. Its running containers are probed from the host at verify (below).
    for img in no_shell:
        out.append((f"a container of {img} cannot reach {EGRESS_PROBES[0]}", proved is not None,
                    f"no shell in the image; the default bridge proved by {proved}" if proved
                    else "no shell in the image and no other image proves the default bridge"))
    for c in containers:
        r = ssh(host, f"docker exec {shlex.quote(c)} sh -c {probe} {EGRESS_PROBES[1]}", check=False)
        how = ""
        if r.returncode in (126, NO_SHELL):   # no shell inside: the host's curl in its network namespace
            r = ssh(host, NSENTER_PROBE.format(c=shlex.quote(c), url=EGRESS_PROBES[1]), check=False)
            how = " (no shell: the host's curl in its network namespace)"
        out.append((f"container {c} cannot reach {EGRESS_PROBES[1]}{how}", r.returncode not in (0, 99, 125, 126, 127),
                    f"exit {r.returncode}"))
    return out


def gitea_config_read(spec: dict) -> tuple[list[str], list[str]]:
    """Each [replica.gitea_config] key as the restored app.ini has it: (lines "section KEY = value",
    mismatches). Only the asked keys are read (python configparser on the host); never the file."""
    gc = spec["replica"].get("gitea_config", {})
    want = [[s, k] for s, kv in gc.items() for k in kv]
    r = ssh(spec["host"], f"sudo python3 -c {shlex.quote(INI_READ_PY)} {GITEA_INI_HOST} {shlex.quote(json.dumps(want))}",
            check=False)
    if r.returncode != 0:
        return [], [f"cannot read {GITEA_INI_HOST} (exit {r.returncode})"]
    got = json.loads(r.stdout.strip().splitlines()[-1])
    lines, bad = [], []
    for s, k in want:
        have, need = got.get(f"{s}.{k}"), ini_value(gc[s][k])
        lines.append(f"[{s}] {k} = {have}")
        same = have is not None and (have.strip().lower() == need if isinstance(gc[s][k], bool) else have.strip() == need)
        if not same:
            bad.append(f"[{s}] {k} = {have}, not {need}")
    return lines, bad


def apply_gitea_config(spec: dict, apply: bool) -> None:
    """[replica.gitea_config] into the restored app.ini, with Gitea's own environment-to-ini (as its
    start does), before the first start; the file keeps its owner. Then each key is read back."""
    gc = spec["replica"].get("gitea_config", {})
    if not gc:
        return
    env = [f"{gitea_env(s, k)}={ini_value(v)}" for s, kv in gc.items() for k, v in kv.items()]
    print(f"gitea_config: {len(env)} key(s) into {GITEA_INI_HOST} with environment-to-ini, before Gitea starts")
    if not apply:
        return
    flags = " ".join(f"-e {shlex.quote(e)}" for e in env)
    ssh(spec["host"], f"set -e; test -f {GITEA_INI_HOST}; own=$(sudo stat -c %u:%g {GITEA_INI_HOST}); "
                      f"cd ~/scripts/{spec['apps_tree']}/apps/gitea; {COMPOSE_ENV}; "
                      f"docker compose -f compose.yml --project-directory . run --rm --no-deps -T "
                      f"--entrypoint environment-to-ini {flags} gitea --config {GITEA_INI}; "
                      f"sudo chown \"$own\" {GITEA_INI_HOST}", stream=True)
    lines, bad = gitea_config_read(spec)
    for line in lines:
        print(f"  {line}")
    if bad:
        raise Fail(f"gitea_config not in app.ini: {'; '.join(bad)}")


def replica_guard(spec: dict, apply: bool) -> None:
    """A replica writes nothing outward: images, egress block, its check, gitea_config; all before any start."""
    images = replica_images(spec, apply)
    print(f"egress block: {BUILD_SETUP}/{REPLICA_EGRESS} ({REPLICA_EGRESS_TABLE}: LAN, established and the "
          f"host's containers only), then {', '.join(EGRESS_PROBES)} must fail from the host and each image")
    if apply:
        build_step(spec["host"], REPLICA_EGRESS)
        results = egress_checks(spec, images)
        for label, ok, detail in results:
            print(f"  [{'OK' if ok else 'FAIL'}] {label}{(': ' + detail) if detail else ''}")
        bad = [c for c in results if not c[1]]
        if bad:
            raise Fail("egress block: " + "; ".join(f"{l} ({d})" for l, _, d in bad))
        print(f"  egress blocked: the host and {len(images)} image(s) reach none of {', '.join(EGRESS_PROBES)}")
    apply_gitea_config(spec, apply)


def phase_apps(spec: dict, apply: bool, late: bool = False) -> None:
    host = spec["host"]
    if spec.get("replica") and not late:
        replica_guard(spec, apply)
    if not starts_apps(spec):
        print(f"replica of {spec['apps_tree']}: start_apps = false; no app is started")
        return
    if late and not apps_in(spec, True):
        print("no app is marked after_external")
    for a in apps_in(spec, late):
        cmds = a.get("start", ["up"])
        if not cmds:
            print(f"start {a['name']}: nothing to start (spec)")
            continue
        sent = ([a["pull_token_env"]] if a.get("pull_token_env") else []) \
            + ([] if spec.get("replica") else a.get("start_env", []))
        print(f"start {a['name']}: {' '.join(cmds)}" + (f" (over SSH stdin: {', '.join(sent)})" if sent else ""))
        if apply:
            cmd, stdin = env_command(app_env(spec, a, start=True), f"{app_script(spec['apps_tree'], a['name'])} {' '.join(cmds)}")
            ssh(host, cmd, stdin=stdin, stream=True, timeout=3600)


def phase_external(spec: dict, apply: bool) -> int:
    host, gaps = spec["host"], 0
    for e in spec.get("external", []):
        if e.get("manual"):
            print(f"external {e['name']}: MANUAL - {e['manual']}")
            gaps += 1
            continue
        repo = Path(os.path.expanduser(e["repo"]))
        for n in e.get("env", []) if apply else []:
            from_env(n, f"[[external]] {e['name']} env")   # set, one line; its commands inherit it
        if e.get("env"):
            print(f"external {e['name']}: from the environment: {', '.join(e['env'])}")
        for c in e["run"]:
            c = c.format(host=host)
            print(f"external {e['name']}: (cd {repo} && {c})")
            if apply:
                r = subprocess.run(c, shell=True, cwd=repo)
                if r.returncode != 0:
                    raise Fail(f"external {e['name']}: exit {r.returncode}")
    return gaps


def runner_entries(host: str) -> list[dict]:
    code, body = gitea("GET", "/admin/actions/runners?limit=100")
    if code != 200:
        raise Fail(f"Gitea runner list: HTTP {code}")
    return [r for r in body.get("runners", []) if r.get("name") == host]


def delete_runner_entry(host: str, apply: bool) -> None:
    for r in runner_entries(host):
        print(f"delete Gitea runner {r['name']} (id {r['id']}, {r.get('status')})")
        if apply:
            code, _ = gitea("DELETE", f"/admin/actions/runners/{r['id']}")
            if code not in (200, 204):
                raise Fail(f"delete runner {r['id']}: HTTP {code}")


def gitlab_runners(spec: dict) -> list[dict]:
    """The spec's GitLab runners, each with its description in GitLab: HOST-NAME."""
    return [{**r, "description": f"{spec['host']}-{r['name']}"}
            for r in spec.get("gitlab_runner", {}).get("runners", [])]


def gl_scope(scope: str) -> tuple[str, str]:
    """group:asyla -> ("group", "/groups/asyla"); project:a/b -> ("project", "/projects/a%2Fb")."""
    kind, _, where = scope.partition(":")
    return kind, f"/{kind}s/{urllib.parse.quote(where, safe='')}"


def gl_scope_id(scope: str) -> int:
    code, body = gitlab("GET", gl_scope(scope)[1])
    if code != 200 or not isinstance(body, dict) or not isinstance(body.get("id"), int):
        raise Fail(f"GitLab {scope}: HTTP {code}")
    return body["id"]


def gl_runner_entries(scope: str, description: str) -> list[dict]:
    """The runners of SCOPE with this description. Listed with a type filter: an unfiltered
    listing shows gitlab.com's shared runners first and pages them at 100, hiding our own."""
    kind, base = gl_scope(scope)
    code, body = gitlab("GET", f"{base}/runners?type={kind}_type&per_page=100")
    if code != 200 or not isinstance(body, list):
        raise Fail(f"GitLab runner list of {scope}: HTTP {code}")
    return [e for e in body if e.get("description") == description]


def delete_gitlab_runner_entries(spec: dict, apply: bool) -> None:
    """Delete the entries GitLab has for the spec's runners (matched by description, HOST-NAME)."""
    for r in gitlab_runners(spec):
        for e in gl_runner_entries(r["scope"], r["description"]):
            print(f"delete GitLab runner {r['description']} (id {e['id']}, {e.get('status')}) from {r['scope']}")
            if apply:
                code, _ = gitlab("DELETE", f"/runners/{e['id']}")
                if code not in (200, 204):
                    raise Fail(f"delete GitLab runner {e['id']}: HTTP {code}")


def create_gitlab_runner(r: dict) -> tuple[int, str]:
    """POST /user/runners for one spec runner: (id, its authentication token). Untagged jobs off,
    access_level GL_ACCESS_LEVEL (https://docs.gitlab.com/api/users/#create-a-runner-linked-to-a-user)."""
    kind, _ = gl_scope(r["scope"])
    body = {"runner_type": f"{kind}_type", f"{kind}_id": gl_scope_id(r["scope"]), "description": r["description"],
            "tag_list": ",".join(r["tags"]), "run_untagged": False, "access_level": GL_ACCESS_LEVEL}
    code, b = gitlab("POST", "/user/runners", body)
    if code != 201 or not isinstance(b, dict) or not b.get("token") or not isinstance(b.get("id"), int):
        raise Fail(f"create GitLab runner {r['description']} in {r['scope']}: HTTP {code}")   # never the body
    return b["id"], b["token"]


def gl_register_args(r: dict) -> list[str]:
    """gitlab-runner register's options for one spec runner (all but --name and the token).
    --limit 1: one job at a time per runner, as on d03."""
    a = ["--url", GITLAB_URL, "--executor", r["executor"], "--limit", "1"]
    if r["executor"] == "docker":
        a += ["--docker-image", r["image"], "--docker-pull-policy", r.get("pull_policy", "if-not-present")]
        for v in r.get("volumes", []):
            a += ["--docker-volumes", v]
    return a


def gl_runner_detail(rid: int) -> dict:
    code, body = gitlab("GET", f"/runners/{rid}")
    if code != 200 or not isinstance(body, dict):
        raise Fail(f"GitLab runner {rid}: HTTP {code}")
    return body


def phase_gitlab_runner(spec: dict, apply: bool) -> None:
    """Each [gitlab_runner] runner: delete GitLab's entries with its description, create a new one
    (POST /user/runners), register it on the host with the new token over SSH stdin
    (build/gitlab-runner/gitlab-runner.sh, sent from GitLab master), then set concurrent and wait
    until GitLab sees each one online. A rebuild makes new runners: no token is kept anywhere but
    the host's /etc/gitlab-runner/config.toml."""
    host, runners = spec["host"], gitlab_runners(spec)
    if not runners:
        print("no [gitlab_runner] in spec")
        return
    print(f"GitLab runners {', '.join(r['description'] for r in runners)}: gitlab-runner from GitLab's apt "
          f"repository ({BUILD_GITLAB_RUNNER}/, sent from GitLab master), a new entry each (token over stdin only)")
    delete_gitlab_runner_entries(spec, apply)

    def gl_run(args: str, stdin: str | None = None) -> None:
        build_run(host, [BUILD_GITLAB_RUNNER], f'bash "$B/{BUILD_GITLAB_RUNNER}/gitlab-runner.sh" {args}',
                  as_root=True, stdin=stdin)

    for r in runners:
        print(f"  {r['description']}: {gl_scope(r['scope'])[0]} runner on {r['scope']}, tags {r['tags']}, "
              f"untagged jobs off; register {shlex.join(gl_register_args(r))}")
    if not apply:
        return
    gl_run("install")
    created = {}
    for r in runners:
        rid, token = create_gitlab_runner(r)
        created[r["description"]] = rid
        print(f"created GitLab runner {r['description']}: id {rid}")
        gl_run(f"register {shlex.quote(r['description'])} {shlex.join(gl_register_args(r))}", stdin=token + "\n")
        token = ""
    gl_run("finish " + shlex.join(r["description"] for r in runners))
    deadline = time.time() + GL_ONLINE_WAIT
    waiting = dict(created)
    while waiting:
        waiting = {d: i for d, i in waiting.items() if gl_runner_detail(i).get("status") != "online"}
        if not waiting:
            break
        if time.time() > deadline:
            raise Fail(f"GitLab runner(s) not online after {GL_ONLINE_WAIT}s: {', '.join(waiting)}")
        time.sleep(10)
    print(f"GitLab runners online: {', '.join(created)}")


def phase_runner(spec: dict, apply: bool, gitea_host: str | None = None) -> None:
    phase_gitea_runner(spec, apply, gitea_host or GITEA_TOKEN_HOST)
    phase_gitlab_runner(spec, apply)


def gitea_hosts() -> list[str]:
    """The hosts that may serve Gitea: a spec with a gitea [[app]] and no [replica] (files only)."""
    out = []
    for p in sorted(REPO.glob("*/host.toml")):
        s = tomllib.loads(p.read_text())
        if not s.get("replica") and any(a.get("name") == "gitea" for a in s.get("app", [])):
            out.append(p.parent.name)
    return out


def require_serving_gitea(gitea_host: str) -> None:
    """Stop unless GITEA_NAME, resolved on GITEA_HOST, is one of that host's own addresses: the
    runner registers against the name, so a token from another Gitea (d04 before the cutover, d03
    after it) would not register, and the build would have deleted the runner's entry first.
    Read-only. The same rule as d04's gitea.sh backup guard (require_serving_host)."""
    r = ssh(gitea_host, GITEA_SERVING_SH, check=False, timeout=60)
    lines = (r.stdout.splitlines() + ["", ""])[:2]
    names, mine = lines[0].split(), lines[1].split()
    if r.returncode != 0 or not names or not set(names) & set(mine):
        raise Fail(f"Gitea host {gitea_host}: {GITEA_NAME} resolves there to {' '.join(names) or 'nothing'}, not to "
                   f"{gitea_host} ({' '.join(mine) or 'no address'}; exit {r.returncode}); its runner token would "
                   f"not register against {GITEA_NAME}. The Gitea host is the one the name points at "
                   f"(GITEA_TOKEN_HOST, or --gitea-host)")
    print(f"Gitea host {gitea_host} serves {GITEA_NAME} ({' '.join(sorted(set(names) & set(mine)))})")


def phase_gitea_runner(spec: dict, apply: bool, gitea_host: str = GITEA_TOKEN_HOST) -> None:
    host = spec["host"]
    if not spec.get("runner", {}).get("enabled"):
        print("Gitea runner disabled in spec")
        return
    registered = ssh(host, "sudo test -s /var/lib/gitea-runner/.runner", check=False).returncode == 0
    script = app_script(host, "gitea-runner")   # always this host's own runner, never the source's
    if not legacy(spec):
        # gitea-runner.sh reads its labels from ../../HOST/host.toml beside itself, which a new
        # host does not keep: run it from a bundle that has both.
        script = "docker/gitea-runner/gitea-runner.sh (sent with HOST/host.toml)"

    def runner(switches: str, stdin: str | None = None) -> None:
        if legacy(spec):
            ssh(host, f"{app_script(host, 'gitea-runner')} {switches}", stdin=stdin, stream=stdin is None)
        else:
            build_run(host, ["docker/gitea-runner", f"{host}/host.toml"],
                      f'bash "$B/docker/gitea-runner/gitea-runner.sh" {switches}', as_root=False, stdin=stdin)

    if registered:
        print(f"{host} is registered locally; install + up only")
        if apply:
            runner("install up")
        return
    require_serving_gitea(gitea_host)
    delete_runner_entry(host, apply)
    print(f"{script} install, register (instance token from {gitea_host}, stdin only), up")
    if not apply:
        return
    runner("install")
    r = ssh(gitea_host, "docker exec -u git gitea gitea actions generate-runner-token", timeout=120)
    token = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if not token:
        raise Fail("no registration token from Gitea")
    runner("register", stdin=token + "\n")
    token = ""
    runner("up")


# ---------------------------------------------------------------- verify and plan

def verify_gitlab_runners(spec: dict, check) -> None:
    """verify's GitLab runner lines: each spec runner has one entry, online, with exactly the
    spec's tags, untagged jobs off and access level GL_ACCESS_LEVEL; the host's gitlab-runner is active with the spec's
    runners only and concurrent = their number."""
    host = spec["host"]
    gl = gitlab_runners(spec)
    for r in gl:
        entries = gl_runner_entries(r["scope"], r["description"])
        check(f"GitLab runner {r['description']} online in {r['scope']}",
              len(entries) == 1 and entries[0].get("status") == "online",
              ", ".join(f"id {e['id']} {e.get('status')}" for e in entries) or "no entry")
        if len(entries) == 1:
            d = gl_runner_detail(entries[0]["id"])
            have = sorted(d.get("tag_list") or [])
            check(f"GitLab runner {r['description']} tags are the spec's, untagged jobs off",
                  have == sorted(r["tags"]) and d.get("run_untagged") is False,
                  f"{have} vs {sorted(r['tags'])}, run_untagged {d.get('run_untagged')}")
            check(f"GitLab runner {r['description']} access level {GL_ACCESS_LEVEL}",
                  d.get("access_level") == GL_ACCESS_LEVEL, f"access_level {d.get('access_level')}")
    if gl:
        # The names and concurrent only: config.toml's token lines are never read here.
        r = ssh(host, "systemctl is-active gitlab-runner; sudo grep -E '^concurrent = |^  name = ' "
                      "/etc/gitlab-runner/config.toml", check=False)
        lines = r.stdout.splitlines()
        names = sorted(l.split("=", 1)[1].strip().strip('"') for l in lines if l.startswith("  name = "))
        conc = next((l.split("=", 1)[1].strip() for l in lines if l.startswith("concurrent = ")), "none")
        want = sorted(x["description"] for x in gl)
        check("gitlab-runner active with the spec's runners only, concurrent = their number",
              lines[:1] == ["active"] and names == want and conc == str(len(gl)),
              f"{lines[:1]} {names} concurrent {conc}")


def verify_host_maintenance(spec: dict, check) -> None:
    """verify's lines for [host_maintenance]: the .pub is the key's public half, the key set's
    modes and owner, the user's authorized_keys holds the key once (marked), known_hosts is the
    spec's pinned list, then, with self_address, the host's own key as its HM_HOST_KEY reads now.
    The host prints public keys and file modes only, never the private key."""
    hm = spec.get("host_maintenance")
    if not hm:
        return
    q = shlex.quote
    facts = (f"K={q(hm['identity'])}; D=$(dirname \"$K\"); H=$(getent passwd {q(hm['user'])} | cut -d: -f6); "
             "P=$(ssh-keygen -y -f \"$K\" 2>/dev/null | cut -d' ' -f1,2); B=${P#* }; "
             "echo \"derived $P\"; echo \"pubfile $(cut -d' ' -f1,2 \"$K.pub\" 2>/dev/null)\"; "
             "for f in \"$D\" \"$K\" \"$K.pub\" \"$D/known_hosts\"; do "
             "echo \"stat $(stat -c '%a %U:%G' \"$f\" 2>/dev/null || echo missing)\"; done; "
             "if [ -n \"$B\" ]; then A=\"$H/.ssh/authorized_keys\"; "
             f"echo \"auth $(grep -cF \" $B\" \"$A\" 2>/dev/null) $(grep -F \" $B\" \"$A\" 2>/dev/null | grep -cF {q(' ' + HM_MARK)})\"; "
             "else echo 'auth - -'; fi; "
             f"echo \"hostkey $(cut -d' ' -f1,2 {q(HM_HOST_KEY)} 2>/dev/null)\"; "
             "echo '--- known_hosts'; cat \"$D/known_hosts\" 2>/dev/null")
    r = ssh(spec["host"], f"sudo bash -c {q(facts)}", check=False)
    head, _, kh = r.stdout.partition("--- known_hosts\n")
    lines = head.splitlines()
    derived = next((l[8:] for l in lines if l.startswith("derived ")), "")
    pubfile = next((l[8:] for l in lines if l.startswith("pubfile ")), "")
    check(f"host-maintenance {hm['identity']}.pub is ssh-keygen -y of the key",
          len(derived.split()) == 2 and derived == pubfile,
          f"...{derived[-8:]} vs ...{pubfile[-8:]}" if derived else "the key does not read")
    owner = hm_owner(spec)
    stats = [l[5:] for l in lines if l.startswith("stat ")]
    want = [f"700 {owner}", f"600 {owner}", f"644 {owner}", f"644 {owner}"]
    check("host-maintenance key dir 700, key 600, .pub and known_hosts 644, owner the secret's",
          stats == want, "; ".join(stats))
    auth = next((l.split()[1:] for l in lines if l.startswith("auth ")), [])
    check(f"{hm['user']}'s authorized_keys holds the host-maintenance key once, marked",
          auth == ["1", "1"], f"{auth[0] if auth else '-'} line(s), {auth[1] if len(auth) > 1 else '-'} marked")
    want = list(hm["known_hosts"])
    label = "host-maintenance known_hosts is the spec's pinned list"
    detail = ""
    if hm.get("self_address"):
        own = next((l[8:].split() for l in lines if l.startswith("hostkey ")), [])
        label += f", then this host's own key as {hm['self_address']}"
        if own[:1] == ["ssh-ed25519"] and len(own) == 2:
            want.append(f"{hm['self_address']} {' '.join(own)}")
        else:
            want.append("")   # never equal: known_hosts holds no empty line
            detail = f"; no ed25519 key in {HM_HOST_KEY}"
    # Any order: ssh does not care, and host-maintenance's add-host.sh appends a new host's line
    # after the own key (d06 on d03, 2026-10-18), where a build writes the pins first.
    have = kh.splitlines()
    extra = sorted({l.split()[0] for l in set(have) - set(want) if l.split()})
    missing = sorted({l.split()[0] for l in set(want) - set(have) if l.split()})
    check(label + " (any order)", sorted(have) == sorted(want),
          f"{len(have)} line(s) vs {len(want)} wanted{detail}"
          + (f"; not wanted: {', '.join(extra)}" if extra else "")
          + (f"; missing: {', '.join(missing)}" if missing else ""))


def verify_externals(spec: dict, check) -> None:
    """verify's lines for [[external]]: an entry with `check` runs it on the host (exit 0 is OK);
    a `manual` entry without one is a note, not a FAIL: verify cannot see whether it was done,
    and a line that always fails hid real failures (d03 cutover, 2026-10-17). A run-only entry
    is proven by its own `run` commands' verify."""
    for e in spec.get("external", []):
        if e.get("check"):
            r = ssh(spec["host"], e["check"], check=False)
            check(f"external {e['name']}: {e['check']}", r.returncode == 0,
                  "" if r.returncode == 0 else f"exit {r.returncode}")
        elif e.get("manual"):
            print(f"  [NOTE] external {e['name']}: manual step, not checked - {e['manual']}")


def verify_apps(spec: dict, check) -> None:
    """verify's lines for each [[app]]: its own verify, else running; for a replica, running only
    (never the source's verify: it curls the source's public URLs), and nothing for an app with
    start = [] (no container: the apps phase starts nothing, 2026-10-17 d03 proof); then restore."""
    host = spec["host"]
    for a in spec.get("app", []):
        name = a["name"]
        if not starts_apps(spec):
            pass   # not started: nothing to verify
        elif spec.get("replica") and not a.get("start", ["up"]):
            print(f"  app {name}: nothing started (start = []), so no container to check")
        elif spec.get("replica") and name in spec["replica"].get("app_verify", []):
            # An app whose verify knows a replica (local checks only): its own verify, as on the source.
            r = ssh(host, f"{app_script(spec['apps_tree'], name)} {' '.join(a['verify'])}", check=False)
            check(f"app {name} (replica)", r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "")
        elif spec.get("replica"):
            # Never the source's verify: it curls the source's public URLs. Running, then [replica].verify.
            r = ssh(host, f"cd ~/scripts/{spec['apps_tree']}/apps/{name} && docker compose ls --format json", check=False)
            running = [p for p in json.loads(r.stdout or "[]") if "running" in p.get("Status", "")
                       and f"/apps/{name}/" in p.get("ConfigFiles", "")]
            check(f"app {name} running", bool(running))
        elif a.get("verify"):
            r = ssh(host, f"{app_script(spec['apps_tree'], name)} {' '.join(a['verify'])}", check=False)
            check(f"app {name}", r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "")
        else:
            r = ssh(host, f"cd ~/scripts/{spec['apps_tree']}/apps/{name} && docker compose ls --format json", check=False)
            running = [p for p in json.loads(r.stdout or "[]") if "running" in p.get("Status", "")
                       and f"/apps/{name}/" in p.get("ConfigFiles", "")]
            check(f"app {name} running", bool(running))
        if a.get("restore") is not False:
            check(f"app {name} restore", *restore_check(spec, name))


def verify(spec: dict) -> int:
    host, bad = spec["host"], 0

    def check(label: str, ok: bool, detail: str = "") -> None:
        nonlocal bad
        bad += not ok
        print(f"  [{'OK' if ok else 'FAIL'}] {label}{(': ' + detail) if detail else ''}")

    r = ssh(host, "hostname -s; id -u docker; findmnt -rno TARGET | grep -E '^/mnt' | tr '\\n' ' '", check=False)
    out = r.stdout.split("\n")
    check("ssh + hostname", r.returncode == 0 and out[0] == host, out[0] if out else "")
    if r.returncode != 0:
        return 1
    check("docker uid 1003", out[1] == "1003", out[1])
    r = ssh(host, "id -gn docker; getent group docker | cut -d: -f3", check=False)
    g = r.stdout.split()
    check("docker group asyla, member of docker (GID 1000)", g[:1] == ["asyla"] and g[1:2] == ["1000"], " ".join(g))
    mounts = out[2].split()
    for m in ["/mnt/nas/data1/docker", "/mnt/nas/data2/docker"] + (["/mnt/docker"] if spec["vm"].get("data_disk") else []):
        check(f"mount {m}", m in mounts)
    if "smb.sh" in spec.get("setup", {}).get("steps", []):
        check("mount /mnt/nas/data1/media", "/mnt/nas/data1/media" in mounts)
    r = ssh(host, "command -v screen", check=False)   # host-maintenance runs its tasks in screen
    check("screen is installed", r.returncode == 0)
    if spec["vm"].get("startup"):
        live = find_vm(spec["vm"]["vmid"])
        r = ssh(root(live["node"]), f"qm config {spec['vm']['vmid']}", check=False) if live else None
        have = next((l.split(": ", 1)[1] for l in (r.stdout.splitlines() if r else []) if l.startswith("startup: ")), "none")
        check("VM start order is the spec's", have == spec["vm"]["startup"], f"{have} vs {spec['vm']['startup']}")
    if spec.get("replica"):
        # GitLab is unreachable by design: the egress block is checked in place of the deploy token.
        r = ssh(host, "docker ps --format '{{.Names}}'", check=False)
        for label, ok, detail in egress_checks(spec, containers=r.stdout.split()):
            check(label, ok, detail)
        if spec["replica"].get("gitea_config"):
            cfg_lines, cfg_bad = gitea_config_read(spec)   # not `bad`: that is verify's own count
            check("gitea_config in the restored app.ini", not cfg_bad and bool(cfg_lines), "; ".join(cfg_bad or cfg_lines))
    elif host in TOKEN_FILE_HOSTS:
        try:
            check("deploy token reads GitLab", bool(check_token(host)))
        except Fail as e:
            check("deploy token reads GitLab", False, str(e))
    else:
        check("no deploy token file on the host", token_file_absent(host), DEPLOY_ENV)
    sha, drift = scripts_drift(spec)
    check(f"~/scripts matches GitLab master {sha[:12]}", not drift,
          f"{len(drift)} differ: {', '.join(drift[:5])}" if drift else "")
    if not legacy(spec):
        paths = " ".join(f"/home/{GUEST_USER}/scripts/{p}" for p in build_only_paths(spec))
        find = (f"shopt -s nullglob; for p in /tmp/{BUILD_DIR_GLOB} /root/{BUILD_DIR_GLOB} {paths}; do "
                f"if [ -e \"$p\" ]; then echo \"$p\"; fi; done")
        r = ssh(host, f"sudo bash -c {shlex.quote(find)}", check=False)
        left = r.stdout.split()
        check("no build files on the host", r.returncode == 0 and not left, " ".join(left))
        r = ssh(host, "test -f /usr/local/share/asyla/docker_bashrc_additions.sh && "
                      "grep -qF /usr/local/share/asyla/docker_bashrc_additions.sh ~/.bashrc", check=False)
        check("bash additions installed (bashrc.sh)", r.returncode == 0)
    if "node_exporter.sh" in spec.get("setup", {}).get("steps", []):
        r = ssh(host, "systemctl is-active prometheus-node-exporter asyla-textfile-sources.timer; "
                      "systemctl show -p IPAddressDeny --value prometheus-node-exporter; "
                      "curl -fsS -m 10 http://127.0.0.1:9100/metrics | grep -E '^node_textfile_scrape_error |^asyla_textfile_source_ok'",
                check=False)
        out = r.stdout.split("\n")
        ok = out[:2] == ["active", "active"] and out[2:3] != [""] and "node_textfile_scrape_error 0" in out
        bad_src = [l.split('file="', 1)[1].split('"', 1)[0] for l in out if l.startswith("asyla_textfile_source_ok{") and l.endswith(" 0")]
        check("node exporter (node_exporter.sh): active, 9100 filtered, textfiles parse", ok, " ".join(out[:3]))
        check("textfile sources copied", ok and not bad_src, ", ".join(bad_src))
    if "port_proxy.sh" in spec.get("setup", {}).get("steps", []):
        # Each proxy's socket is filtered, and an HTTP GET through it reaches the container (every
        # proxied target today is an exporter's web page).
        for p in spec.get("port_proxy", []):
            unit = f"asyla-proxy-{p['name']}.socket"
            r = ssh(host, f"systemctl is-active {unit}; systemctl show -p IPAddressDeny --value {unit}; "
                          f"curl -fsS -m 10 -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{int(p['listen'])}/",
                    check=False)
            out = r.stdout.split("\n")
            ok = out[:1] == ["active"] and out[1:2] != [""] and out[2:3] == ["200"]
            check(f"port proxy {p['name']} (port_proxy.sh): :{p['listen']} filtered, reaches {p['target']}",
                  ok, " ".join(out[:3]))
    if spec["vm"].get("data_disk"):
        r = ssh(host, "findmnt -no SOURCE /; findmnt -no SOURCE /mnt/docker", check=False)
        src = r.stdout.split()
        check("/mnt/docker on its own disk", len(src) == 2 and src[0] != src[1], " vs ".join(src))
    if spec.get("replica"):
        r = ssh(host, "findmnt -no OPTIONS /mnt/nas/data1/docker; findmnt -no OPTIONS /mnt/nas/data2/docker", check=False)
        opts = [o.split(",")[0] for o in r.stdout.split()]
        check("NAS docker shares read-only (replica: no backup can reach the source's mirrors)",
              opts == ["ro", "ro"], " ".join(opts))
    if not starts_apps(spec):
        # The source's app verify would curl the source's public URLs and pass falsely here.
        r = ssh(host, "docker ps --format '{{.Names}}'", check=False)
        names = r.stdout.split()
        check("no app container running (start_apps = false)", r.returncode == 0 and not names, " ".join(names))
        r = ssh(host, f"sudo du -sh {DATA_ROOT}* 2>/dev/null", check=False)
        print("  data: " + "; ".join(" ".join(l.split()[::-1]) for l in r.stdout.splitlines()))
    verify_apps(spec, check)
    for u in spec.get("replica", {}).get("verify", []) if starts_apps(spec) else []:
        url = u.format(ip=ip_only(spec))
        r = ssh(host, f"for i in $(seq 60); do curl -sf -o /dev/null -m 5 {shlex.quote(url)} && exit 0; sleep 2; done; "
                      f"exit 1", check=False, timeout=600)
        check(f"replica answers {url}", r.returncode == 0, "" if r.returncode == 0 else "not within 120 s")
    if spec.get("runner", {}).get("enabled"):
        entries = runner_entries(host)
        online = [e for e in entries if e.get("status") in ("online", "idle", "active")]
        check("Gitea runner online", len(entries) == 1 and bool(online),
              ", ".join(f"id {e['id']} {e.get('status')} {[l['name'] for l in e.get('labels', [])]}" for e in entries))
        want = spec["runner"].get("labels")
        if want:
            have = sorted({l["name"].split(":")[0] for e in entries for l in e.get("labels", [])})
            check("Gitea runner labels are the spec's", have == sorted(want), f"{have} vs {sorted(want)}")
    verify_gitlab_runners(spec, check)
    verify_host_maintenance(spec, check)
    verify_externals(spec, check)
    return 1 if bad else 0


def plan(spec: dict) -> int:
    host, vm = spec["host"], spec["vm"]
    print(f"{host}: VMID {vm['vmid']} on {vm['node']}, {vm['sockets']}x{vm['cores']} cores, "
          f"{vm['memory_mb']} MB, {vm['ip']}, os {vm['os_disk']}, data {vm.get('data_disk', 'none')}")
    live = find_vm(vm["vmid"])
    if not live:
        print("  live: no such VM")
    else:
        print(f"  live: {live.get('name')} on {live.get('node')} ({live.get('status')}), "
              f"{live.get('maxmem', 0) // 2**20} MB, {live.get('maxcpu')} vCPU")
        diffs = []
        if live.get("node") != vm["node"] and not vm.get("disposable"):   # a disposable host may be on either node
            diffs.append(f"node {live.get('node')} != {vm['node']}")
        if live.get("maxmem", 0) // 2**20 != vm["memory_mb"]:
            diffs.append("memory")
        if live.get("maxcpu") != vm["sockets"] * vm["cores"]:
            diffs.append("cpu")
        print(f"  spec vs live: {'matches' if not diffs else 'DIFFERS: ' + ', '.join(diffs)}")
    if spec.get("replica"):
        print(f"  replica of {spec['apps_tree']}: apps from ~/scripts/{spec['apps_tree']}/, "
              f"start_apps = {starts_apps(spec)}, excluded secrets {spec['replica'].get('exclude_secrets', [])}")
        print(f"  replica egress blocked ({REPLICA_EGRESS}) before any start; gitea_config: "
              f"{sum(len(kv) for kv in spec['replica'].get('gitea_config', {}).values())} key(s); "
              f"verify URLs: {spec['replica'].get('verify', [])}")
    print(f"  secrets: {len(spec.get('secret', []))}; apps: {', '.join(a['name'] for a in spec.get('app', []))}")
    gaps = sum(1 for e in spec.get("external", []) if e.get("manual"))
    print(f"  externals: {len(spec.get('external', []))} ({gaps} manual)")
    for r in gitlab_runners(spec):
        print(f"  GitLab runner {r['description']}: {r['scope']}, {r['executor']}, tags {r['tags']}")
    hm = spec.get("host_maintenance")
    if hm:
        print(f"  host-maintenance key set: {hm['identity']} (+ .pub, known_hosts: "
              f"{', '.join(p.split()[0] for p in hm['known_hosts'])}"
              + (f"; own key as {hm['self_address']}, read on the host" if hm.get("self_address") else "")
              + f"), authorized for {hm['user']}")
    return 0


# ---------------------------------------------------------------- main

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """The command line as the Usage block above shows it; options may stand anywhere."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("host")
    ap.add_argument("action", choices=["plan", "build", "verify", "token", "scripts-check", "secrets", "destroy"])
    ap.add_argument("args", nargs="*", help="for the secrets action: check, push or install, then optional VAR "
                                            "names; or copy VAR FROM_VAR")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--keys", action="store_true", help="for secrets check: per key of a dotenv secret, "
                                                        "same, DIFFERS, only in GitLab or only on host")
    ap.add_argument("--from", dest="start", choices=PHASES)
    ap.add_argument("--only", choices=PHASES)
    ap.add_argument("--app", dest="apps", action="append", metavar="NAME",
                    help="with --only apps or late: start only these [[app]]s (one new app on a running host)")
    ap.add_argument("--step", dest="steps", action="append", metavar="SCRIPT",
                    help="with --only setup: run only these [setup].steps (one new step on a running host; "
                         "host_maintenance_keys.sh only when named)")
    ap.add_argument("--recreate", action="store_true")
    ap.add_argument("--confirm")
    ap.add_argument("--node", choices=NODES, help="create the VM on this node (a disposable spec only)")
    ap.add_argument("--gitea-host", help=f"the host whose Gitea makes the runner registration token "
                                         f"(default {GITEA_TOKEN_HOST}); it must serve {GITEA_NAME}")
    # Intermixed: plain parse_args() fills `args` before the first option and then refuses a VAR
    # after it, so `secrets push --apply VAR` (the documented order) was a usage error.
    a = ap.parse_intermixed_args(argv)
    if a.args and a.action != "secrets":
        ap.error(f"{a.action} takes no further arguments: {' '.join(a.args)}")
    if a.keys and (a.action != "secrets" or a.args[:1] != ["check"]):
        ap.error("--keys is for secrets check only")
    if a.apps and (a.action != "build" or a.only not in ("apps", "late")):
        ap.error("--app is for build --only apps or --only late")
    if a.steps and (a.action != "build" or a.only != "setup"):
        ap.error("--step is for build --only setup")
    if a.gitea_host is not None:
        if a.action != "build":
            ap.error(f"--gitea-host is for build (its runner phase), not {a.action}")
        if a.gitea_host not in gitea_hosts():
            ap.error(f"--gitea-host {a.gitea_host}: not a host whose spec has a gitea [[app]] and no "
                     f"[replica] ({', '.join(gitea_hosts())})")
    return a


def main() -> int:
    a = parse_args()
    try:
        spec = load_spec(a.host, a.node)
        if spec.get("hold") and a.action in ("build", "destroy"):
            raise Fail(f"{a.host} is on hold: {spec['hold']}")
        if a.action == "plan":
            return plan(spec)
        if a.action == "verify":
            return verify(spec)
        if a.action == "scripts-check":
            sha, drift = scripts_drift(spec)
            print(f"{a.host}: ~/scripts vs GitLab master {sha[:12]}: "
                  f"{'matches' if not drift else str(len(drift)) + ' differ'}")
            for d in drift:
                print(f"  {d}")
            return 1 if drift else 0
        if a.action == "token":
            if a.host not in TOKEN_FILE_HOSTS:
                remove_token_file(a.host, a.apply)
                check_stdin_read(a.host)
                if a.apply and not token_file_absent(a.host):
                    raise Fail(f"{a.host}: {DEPLOY_ENV} still present")
                return 0
            if a.apply:
                install_token(a.host, True)
            else:
                install_token(a.host, False)
                try:
                    check_token(a.host)
                except Fail as e:
                    print(f"not usable yet: {e}")
            return 0
        if a.action == "secrets":
            if a.args and a.args[0] == "copy":
                if len(a.args) != 3:
                    raise Fail("secrets copy needs VAR FROM_VAR")
                return secret_copy(spec, a.args[1], a.args[2], a.apply)
            if not a.args or a.args[0] not in ("check", "push", "install"):
                raise Fail("secrets needs check|push|install, or copy VAR FROM_VAR")
            return secrets_cmd(spec, a.args[0], a.apply, a.args[1:], keys=a.keys)
        if a.action == "destroy":
            live = find_vm(spec["vm"]["vmid"])
            if not live:
                print("no such VM")
                return 0
            if live.get("name") != a.host:
                raise Fail(f"VMID {spec['vm']['vmid']} is {live.get('name')}, not {a.host}")
            if not spec["vm"].get("disposable") and a.confirm != a.host:
                raise Fail(f"{a.host} is not disposable: destroy needs --confirm {a.host} (and the operator's approval)")
            destroy_vm(spec, a.apply, live["node"])
            return 0
        if a.apps:
            unknown = sorted(set(a.apps) - {x["name"] for x in spec.get("app", [])})
            if unknown:
                raise Fail(f"--app {', '.join(unknown)}: not an [[app]] of {a.host}")
            spec["app"] = [x for x in spec["app"] if x["name"] in a.apps]
        if a.steps:
            select_steps(spec, a.steps)
        phases = list(PHASES)
        if a.only:
            phases = [a.only]
        elif a.start:
            phases = phases[phases.index(a.start):]
        if not a.apply:
            print("DRY RUN (no --apply): showing what each phase would do")
        gaps = 0
        if "vm" in phases or env_needed(spec, phases):
            step("pre-flight")
        if "vm" in phases:
            preflight_secrets(spec, a.apply)
        preflight_env(spec, phases, a.apply)
        for p in phases:
            step(p)
            if p == "vm":
                phase_vm(spec, a.apply, a.recreate, a.confirm)
            elif p == "bootstrap":
                phase_bootstrap(spec, a.apply)
            elif p == "disk":
                phase_disk(spec, a.apply)
            elif p == "secrets":
                # Alone (--only secrets) it installs every secret; in a build, app-data ones wait for restore.
                if secrets_cmd(spec, "install", a.apply, [], data=None if a.only else False):
                    raise Fail("a secret is missing in GitLab")
            elif p == "setup":
                phase_setup(spec, a.apply)
            elif p == "restore":
                phase_restore(spec, a.apply)
            elif p == "apps":
                phase_apps(spec, a.apply)
            elif p == "external":
                gaps += phase_external(spec, a.apply)
            elif p == "late":
                phase_apps(spec, a.apply, late=True)
            elif p == "runner":
                phase_runner(spec, a.apply, a.gitea_host)
            elif p == "verify" and a.apply:
                if verify(spec):
                    raise Fail("verify failed")
        print(f"\ndone{'' if a.apply else ' (dry run)'}{f'; {gaps} manual external step(s)' if gaps else ''}")
        return 0
    except Fail as e:
        print(f"\nFAILED: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
