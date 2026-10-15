#!/usr/bin/env python3
"""Build, rebuild and verify a Docker host (d0N, or the test host test01) from its spec, from the workstation.

asyla hub decisions/host-build-and-recovery.md: a rebuild must reproduce everything a host runs,
from nothing but GitLab (this repo, its CI/CD variables), the NAS backups and the hypervisor.

Usage:
  build_host.py HOST plan                      # read-only: spec, live VM, gaps
  build_host.py HOST build [--apply] [--from PHASE] [--only PHASE] [--recreate [--confirm HOST]]
                           [--node NODE]
  build_host.py HOST verify                    # read-only
  build_host.py HOST token [--apply]           # deploy token file alone, then a GitLab read check
  build_host.py HOST scripts-check             # read-only: ~/scripts vs GitLab master, file by file
  build_host.py HOST secrets check|push|install [--apply] [VAR ...]
  build_host.py HOST secrets copy [--apply] VAR FROM_VAR   # VAR created in GitLab from FROM_VAR's value
  build_host.py HOST destroy --apply [--confirm HOST]

Build phases, in order (each is safe to re-run):
  vm         create the VM from HOST/host.toml (skipped when it exists; --recreate destroys it
             first: allowed freely only for a spec with disposable = true, else needs --confirm HOST)
  bootstrap  deploy token to /etc/asyla/asyla-hosts.env, then the host's update_scripts.sh
             (from GitLab master, the same file the host will keep running)
  disk       data disk -> /mnt/docker (build/setup/data_disk.sh; never formats a disk with data)
  secrets    every [[secret]] from GitLab CI/CD variables to its path, except those under
             /mnt/docker/ (app data), which restore installs after the data is back
  setup      build/setup/<step> for each [setup].steps, as root
  restore    `<app>.sh restore` for each app whose data is empty (from its NAS mirror), then the
             secrets under /mnt/docker/ (a restore refuses a non-empty data dir)
  apps       each app's start commands (default: up), in spec order, except the apps marked
             after_external = true
  external   other repos' deploy commands from the workstation; `manual` entries are listed
  late       the apps marked after_external = true: those that need this host's proxy or tunnel
             up before they start (an app that pulls its images through the proxy)
  runner     Gitea runner: delete this host's stale entry, install, register, up; then each
             [gitlab_runner] runner: delete GitLab's entries with its description (HOST-NAME),
             create a new one (POST /user/runners, untagged jobs off), register it on the host
             (build/gitlab-runner/gitlab-runner.sh; the token over SSH stdin, into gitlab-runner's
             environment), concurrent = the number of runners, wait until online
  verify     mounts, every app's verify (or running containers), runners online with the spec's
             labels or tags

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
key, /etc/gitlab-runner/config.toml and the unit. The legacy hosts d01 to d03 (LEGACY_HOSTS)
keep HOST/setup/ and their old phases until each is replaced (operator: "Let the legacy servers
behave in their legacy ways"); any other spec is refused if HOST/setup/ exists or a step is not
in build/setup/.

Start order: an optional [vm].startup (Proxmox's form, "order=N[,up=S][,down=S]") is set when the
VM is created and checked by verify.

Node: [vm].node is where the VM is created. --node NODE overrides it for a spec with
disposable = true only (the test host may run on either node); a production host's node is its
spec's. Hold: a spec with a top-level hold = "reason" is not built or destroyed.

Guests are reached as docker@HOST with ~/.ssh/docker_rsa, the user and key the vm phase gives
them, so a host needs no entry in the workstation's ssh config.

Replica: a spec with [replica] of = "dNN" (test01 as a d03 replica) takes the source spec's
[[secret]] and [[app]] lists (minus exclude_secrets) and runs the apps from ~/scripts/dNN/ (its
updater installs that tree too). Its own [vm], [setup] and [runner] apply, and the source's
[[external]] never do: a replica must not answer for the source's hostnames. With
start_apps = false the apps phase starts nothing and verify checks that no container runs.
[gitlab_runner] is the host's own, never the source's.

GitLab runners: [gitlab_runner] runners = [{name, scope = "group:PATH" | "project:GROUP/PROJECT",
tags, executor = "docker" | "shell", and for docker image, volumes, pull_policy}]. A rebuild
makes new runners (no GitLab CI secret holds a runner token); destroy deletes them. Listings are
type-filtered (/groups/ID/runners?type=group_type): unfiltered, gitlab.com's shared runners
fill the first page.

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
GITEA_TOKEN_HOST = "d03"
LEGACY_HOSTS = ("d01", "d02", "d03")   # HOST/setup/ on the host, run from ~/scripts (the old way)
BUILD_SETUP = "build/setup"
BUILD_GITLAB_RUNNER = "build/gitlab-runner"
GITLAB_URL = "https://gitlab.com"
GL_RUNNER_NAME = re.compile(r"[a-z0-9][a-z0-9-]*")
GL_RUNNER_SCOPE = re.compile(r"(group|project):[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*")
GL_RUNNER_TAG = re.compile(r"[A-Za-z0-9_.:-]+")
GL_EXECUTORS = ("docker", "shell")
GL_PULL_POLICIES = ("always", "if-not-present", "never")
GL_ONLINE_WAIT = 180           # seconds the runner phase waits for a new GitLab runner to be online
NODES = ("vmh01", "vmh02")
IMAGE = "/mnt/nas/data1/iso/template/iso/debian-13-generic-amd64.qcow2"
GATEWAY = "10.0.0.1"
NAMESERVERS = "10.0.0.10 10.0.0.11"
SEARCHDOMAIN = "asyla.org"
BRIDGE, VLAN = "vmbr1", 100
SSH_KEY_PUB = Path.home() / ".ssh/docker_rsa.pub"
SSH_KEY = SSH_KEY_PUB.with_suffix("")
GUEST_USER = "docker"
DEPLOY_ENV = "/etc/asyla/asyla-hosts.env"
DATA_ROOT = "/mnt/docker/"
PHASES = ("vm", "bootstrap", "disk", "secrets", "setup", "restore", "apps", "external", "late", "runner", "verify")
STARTUP_FORM = re.compile(r"order=\d+(,up=\d+)?(,down=\d+)?")
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
        excl = set(rep.get("exclude_secrets", []))
        unknown = excl - {s["var"] for s in src_spec.get("secret", [])}
        if unknown:
            raise Fail(f"{path}: exclude_secrets not in {src}: {sorted(unknown)}")
        # live_on: where the running copy of a secret file is (the pre-flight compares it there).
        spec["secret"] = [{**s, "live_on": src} for s in src_spec.get("secret", []) if s["var"] not in excl] \
            + spec.get("secret", [])
        spec["app"] = src_spec.get("app", [])
        spec["apps_tree"] = src
        if spec.get("external"):
            raise Fail(f"{path}: a replica has no [[external]] (it must not answer for {src}'s names)")
    for s in spec.get("secret", []):
        if not s.get("var", "").replace("_", "").isalnum():
            raise Fail(f"{path}: bad secret var {s.get('var')!r}")
    if host not in LEGACY_HOSTS:
        own = REPO / host / "setup"
        if own.is_dir() and any(own.iterdir()):
            raise Fail(f"{REPO / host / 'setup'}: a host has no build scripts of its own; they are in {BUILD_SETUP}/")
        missing = [s for s in spec.get("setup", {}).get("steps", []) if not (REPO / BUILD_SETUP / s).is_file()]
        if missing:
            raise Fail(f"{path}: [setup].steps not in {BUILD_SETUP}/: {missing}")
    return spec


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


# The same credential helper update_scripts.sh uses: reads DEPLOY_ENV, never puts the token in argv.
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
    install_token(host, apply)
    print(f"then {host}/update_scripts.sh from GitLab master")
    script = master_file(f"{host}/update_scripts.sh")
    if not apply:
        return
    ssh(host, "sudo apt-get install -y -qq git curl rsync >/dev/null", timeout=900)
    ssh(host, "cat > /tmp/update_scripts.sh && sudo bash /tmp/update_scripts.sh; rc=$?; rm -f /tmp/update_scripts.sh; exit $rc",
        stdin=script, stream=True)


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


def phase_setup(spec: dict, apply: bool) -> None:
    host = spec["host"]
    for s in spec.get("setup", {}).get("steps", []):
        print(f"setup: {s}" + ("" if legacy(spec) else f" ({BUILD_SETUP}/, sent from GitLab master)"))
        if apply:
            if legacy(spec):
                ssh(host, f"sudo ~/scripts/{host}/setup/{s}", stream=True, timeout=3600)
            else:
                build_step(host, s)


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


def in_app_data(s: dict) -> bool:
    return s["path"].startswith(DATA_ROOT)


def secrets_cmd(spec: dict, action: str, apply: bool, only: list[str], data: bool | None = None) -> int:
    """data: None = every secret, False = those outside DATA_ROOT, True = those under it."""
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

def app_has(spec: dict, app: str, switch: str) -> bool:
    r = ssh(spec["host"], f"grep -qE '^[[:space:]]+([a-z_|-]+\\|)?{switch}(\\|[a-z_|-]+)?\\)' "
                          f"{app_script(spec['apps_tree'], app)}", check=False)
    return r.returncode == 0


def phase_restore(spec: dict, apply: bool) -> None:
    host = spec["host"]
    for a in spec.get("app", []):
        name = a["name"]
        if a.get("restore") is False:
            print(f"restore {name}: not applicable (spec)")
            continue
        if not app_has(spec, name, "restore"):
            print(f"restore {name}: GAP - {name}.sh has no restore")
            continue
        print(f"restore {name} (skipped by the app when its data dir is not empty)")
        if apply:
            r = ssh(host, f"{app_script(spec['apps_tree'], name)} restore", check=False, stream=True, timeout=7200)
            if r.returncode != 0:
                print(f"  restore {name}: exit {r.returncode} (data present, or no complete backup); continuing")
    print(f"secrets under {DATA_ROOT} (after the data, so a restore finds its data dir empty):")
    if secrets_cmd(spec, "install", apply, [], data=True):
        raise Fail("a secret is missing in GitLab")


def apps_in(spec: dict, late: bool) -> list[dict]:
    """The apps of one start phase: `apps` (before the externals) or `late` (after them)."""
    return [a for a in spec.get("app", []) if bool(a.get("after_external")) == late]


def phase_apps(spec: dict, apply: bool, late: bool = False) -> None:
    host = spec["host"]
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
        print(f"start {a['name']}: {' '.join(cmds)}")
        if apply:
            ssh(host, f"{app_script(spec['apps_tree'], a['name'])} {' '.join(cmds)}", stream=True, timeout=3600)


def phase_external(spec: dict, apply: bool) -> int:
    host, gaps = spec["host"], 0
    for e in spec.get("external", []):
        if e.get("manual"):
            print(f"external {e['name']}: MANUAL - {e['manual']}")
            gaps += 1
            continue
        repo = Path(os.path.expanduser(e["repo"]))
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
    """POST /user/runners for one spec runner: (id, its authentication token). Untagged jobs off."""
    kind, _ = gl_scope(r["scope"])
    body = {"runner_type": f"{kind}_type", f"{kind}_id": gl_scope_id(r["scope"]), "description": r["description"],
            "tag_list": ",".join(r["tags"]), "run_untagged": False}
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


def phase_runner(spec: dict, apply: bool) -> None:
    phase_gitea_runner(spec, apply)
    phase_gitlab_runner(spec, apply)


def phase_gitea_runner(spec: dict, apply: bool) -> None:
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
    delete_runner_entry(host, apply)
    print(f"{script} install, register (instance token from {GITEA_TOKEN_HOST}, stdin only), up")
    if not apply:
        return
    runner("install")
    r = ssh(GITEA_TOKEN_HOST, "docker exec -u git gitea gitea actions generate-runner-token", timeout=120)
    token = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if not token:
        raise Fail("no registration token from Gitea")
    runner("register", stdin=token + "\n")
    token = ""
    runner("up")


# ---------------------------------------------------------------- verify and plan

def verify_gitlab_runners(spec: dict, check) -> None:
    """verify's GitLab runner lines: each spec runner has one entry, online, with exactly the
    spec's tags and untagged jobs off; the host's gitlab-runner is active with the spec's
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
    try:
        check("deploy token reads GitLab", bool(check_token(host)))
    except Fail as e:
        check("deploy token reads GitLab", False, str(e))
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
    for a in spec.get("app", []):
        name = a["name"]
        if not starts_apps(spec):
            pass   # not started: nothing to verify
        elif a.get("verify"):
            r = ssh(host, f"{app_script(spec['apps_tree'], name)} {' '.join(a['verify'])}", check=False)
            check(f"app {name}", r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "")
        else:
            r = ssh(host, f"cd ~/scripts/{spec['apps_tree']}/apps/{name} && docker compose ls --format json", check=False)
            running = [p for p in json.loads(r.stdout or "[]") if "running" in p.get("Status", "")
                       and f"/apps/{name}/" in p.get("ConfigFiles", "")]
            check(f"app {name} running", bool(running))
        if a.get("restore") is not False:
            has = app_has(spec, name, "restore")
            check(f"app {name} restore", has, "" if has else "no restore switch")
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
    for e in spec.get("external", []):
        if e.get("manual"):
            check(f"external {e['name']}", False, "manual step, not automated yet")
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
    print(f"  secrets: {len(spec.get('secret', []))}; apps: {', '.join(a['name'] for a in spec.get('app', []))}")
    gaps = sum(1 for e in spec.get("external", []) if e.get("manual"))
    print(f"  externals: {len(spec.get('external', []))} ({gaps} manual)")
    for r in gitlab_runners(spec):
        print(f"  GitLab runner {r['description']}: {r['scope']}, {r['executor']}, tags {r['tags']}")
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
    ap.add_argument("--from", dest="start", choices=PHASES)
    ap.add_argument("--only", choices=PHASES)
    ap.add_argument("--recreate", action="store_true")
    ap.add_argument("--confirm")
    ap.add_argument("--node", choices=NODES, help="create the VM on this node (a disposable spec only)")
    # Intermixed: plain parse_args() fills `args` before the first option and then refuses a VAR
    # after it, so `secrets push --apply VAR` (the documented order) was a usage error.
    a = ap.parse_intermixed_args(argv)
    if a.args and a.action != "secrets":
        ap.error(f"{a.action} takes no further arguments: {' '.join(a.args)}")
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
            return secrets_cmd(spec, a.args[0], a.apply, a.args[1:])
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
        phases = list(PHASES)
        if a.only:
            phases = [a.only]
        elif a.start:
            phases = phases[phases.index(a.start):]
        if not a.apply:
            print("DRY RUN (no --apply): showing what each phase would do")
        gaps = 0
        if "vm" in phases:
            step("pre-flight")
            preflight_secrets(spec, a.apply)
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
                phase_runner(spec, a.apply)
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
