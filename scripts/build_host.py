#!/usr/bin/env python3
"""Build, rebuild and verify a d0N Docker host from its spec, from the workstation.

asyla hub decisions/host-build-and-recovery.md: a rebuild must reproduce everything a host runs,
from nothing but GitLab (this repo, its CI/CD variables), the NAS backups and the hypervisor.

Usage:
  build_host.py HOST plan                      # read-only: spec, live VM, gaps
  build_host.py HOST build [--apply] [--from PHASE] [--only PHASE] [--recreate [--confirm HOST]]
  build_host.py HOST verify                    # read-only
  build_host.py HOST token [--apply]           # deploy token file alone, then a GitLab read check
  build_host.py HOST scripts-check             # read-only: ~/scripts vs GitLab master, file by file
  build_host.py HOST secrets check|push|install [--apply] [VAR ...]
  build_host.py HOST destroy --apply [--confirm HOST]

Build phases, in order (each is safe to re-run):
  vm         create the VM from HOST/host.toml (skipped when it exists; --recreate destroys it
             first: allowed freely only for a spec with disposable = true, else needs --confirm HOST)
  bootstrap  deploy token to /etc/asyla/asyla-hosts.env, then the host's update_scripts.sh
             (from GitLab master, the same file the host will keep running)
  disk       data disk -> /mnt/docker (docker/setup/data_disk.sh; never formats a disk with data)
  secrets    every [[secret]] from GitLab CI/CD variables to its path, except those under
             /mnt/docker/ (app data), which restore installs after the data is back
  setup      HOST/setup/<step> for each [setup].steps, as root
  restore    `<app>.sh restore` for each app whose data is empty (from its NAS mirror), then the
             secrets under /mnt/docker/ (a restore refuses a non-empty data dir)
  apps       each app's start commands (default: up), in spec order
  external   other repos' deploy commands from the workstation; `manual` entries are listed
  runner     Gitea runner: delete this host's stale entry, install, register, up
  verify     mounts, every app's verify (or running containers), runner online

Replica: a spec with [replica] of = "dNN" (d04 as a d03 replica) takes the source spec's
[[secret]] and [[app]] lists (minus exclude_secrets) and runs the apps from ~/scripts/dNN/ (its
updater installs that tree too). Its own [vm], [setup] and [runner] apply, and the source's
[[external]] never do: a replica must not answer for the source's hostnames. With
start_apps = false the apps phase starts nothing and verify checks that no container runs.

Nothing here prints a secret (SEC): tokens and secret files move over SSH stdin or HTTPS bodies.
Credentials come from the hub .env (~/local/hub/.env, or KNOWLEDGE_HUB_DOTENV): GITLAB_TOKEN,
GITEA_TOKEN, ASYLA_HOSTS_DEPLOY_USER / ASYLA_HOSTS_DEPLOY_TOKEN.

Exit: 0 ok, 1 a step or check failed, 2 usage or spec error.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
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
NODES = ("vmh01", "vmh02")
IMAGE = "/mnt/nas/data1/iso/template/iso/debian-13-generic-amd64.qcow2"
GATEWAY = "10.0.0.1"
NAMESERVERS = "10.0.0.10 10.0.0.11"
SEARCHDOMAIN = "asyla.org"
BRIDGE, VLAN = "vmbr1", 100
SSH_KEY_PUB = Path.home() / ".ssh/docker_rsa.pub"
DEPLOY_ENV = "/etc/asyla/asyla-hosts.env"
DATA_ROOT = "/mnt/docker/"
PHASES = ("vm", "bootstrap", "disk", "secrets", "setup", "restore", "apps", "external", "runner", "verify")
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]


class Fail(Exception):
    pass


# ---------------------------------------------------------------- environment and remote calls

def hub_env() -> dict[str, str]:
    path = Path(os.environ.get("KNOWLEDGE_HUB_DOTENV") or Path.home() / "local/hub/.env")
    env: dict[str, str] = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


ENV = hub_env()


def need(key: str) -> str:
    v = os.environ.get(key) or ENV.get(key, "")
    if not v:
        raise Fail(f"{key} is not set (hub .env)")
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


def ssh(target: str, command: str, stdin: str | None = None, timeout: int = 1800,
        check: bool = True, stream: bool = False) -> subprocess.CompletedProcess:
    if stream:
        r = subprocess.run(SSH + [target, command], input=stdin if stdin is not None else "",
                           text=True, timeout=timeout)
        if check and r.returncode != 0:
            raise Fail(f"exit {r.returncode} on {target}: {command[:80]}")
        return r
    return run(SSH + [target, command], stdin=stdin, timeout=timeout, check=check)


def root(node: str) -> str:
    return f"root@{node}"


def http(method: str, url: str, headers: dict, body: dict | None = None) -> tuple[int, object]:
    req = urllib.request.Request(url, method=method, headers={**headers, "Content-Type": "application/json"},
                                 data=json.dumps(body).encode() if body is not None else None)
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


def gitlab(method: str, path: str, body: dict | None = None) -> tuple[int, object]:
    return http(method, GITLAB_API + path, {"PRIVATE-TOKEN": need("GITLAB_TOKEN")}, body)


def gitea(method: str, path: str) -> tuple[int, object]:
    return http(method, GITEA_API + path, {"Authorization": f"token {need('GITEA_TOKEN')}"})


def step(msg: str) -> None:
    print(f"\n== {msg}", flush=True)


# ---------------------------------------------------------------- spec

def load_spec(host: str) -> dict:
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
        spec["secret"] = [s for s in src_spec.get("secret", []) if s["var"] not in excl] + spec.get("secret", [])
        spec["app"] = src_spec.get("app", [])
        spec["apps_tree"] = src
        if spec.get("external"):
            raise Fail(f"{path}: a replica has no [[external]] (it must not answer for {src}'s names)")
    for s in spec.get("secret", []):
        if not s.get("var", "").replace("_", "").isalnum():
            raise Fail(f"{path}: bad secret var {s.get('var')!r}")
    return spec


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
        f"--agent 1,fstrim_cloned_disks=1",
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
        r = subprocess.run(SSH + opts + [host, "true"], capture_output=True, text=True)
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


def scripts_drift(spec: dict) -> tuple[str, list[str]]:
    """GitLab master's SHA and the tracked HOST/, replica source and docker/ paths whose ~/scripts copy differs."""
    host = spec["host"]
    trees = sorted({host, spec["apps_tree"], "docker"})
    run(["git", "-C", str(REPO), "fetch", "-q", "origin", "master"])
    sha = run(["git", "-C", str(REPO), "rev-parse", "origin/master"]).stdout.strip()
    want = {}
    for line in run(["git", "-C", str(REPO), "ls-tree", "-r", "origin/master", "--", *trees]).stdout.splitlines():
        meta, _, path = line.partition("\t")
        if meta.split()[1] == "blob":
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
        ssh(host, f"sudo ~/scripts/docker/setup/data_disk.sh scsi2 /mnt/docker {owner}", stream=True)


def phase_setup(spec: dict, apply: bool) -> None:
    host = spec["host"]
    for s in spec.get("setup", {}).get("steps", []):
        print(f"setup: {s}")
        if apply:
            ssh(host, f"sudo ~/scripts/{host}/setup/{s}", stream=True, timeout=3600)


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
    items = [s for s in spec.get("secret", []) if (not only or s["var"] in only)
             and (data is None or in_app_data(s) == data)]
    for s in items:
        key, path = s["var"], s["path"]
        if action == "check":
            g, h = gitlab_secret(key), host_secret(host, path)
            state = ("in sync" if g == h else "DIFFERS") if g is not None and h is not None else \
                    ("MISSING in GitLab" if g is None and h is not None else
                     "MISSING on host" if h is None and g is not None else "MISSING everywhere")
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


def phase_apps(spec: dict, apply: bool) -> None:
    host = spec["host"]
    if not starts_apps(spec):
        print(f"replica of {spec['apps_tree']}: start_apps = false; no app is started")
        return
    for a in spec.get("app", []):
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


def phase_runner(spec: dict, apply: bool) -> None:
    host = spec["host"]
    if not spec.get("runner", {}).get("enabled"):
        print("runner disabled in spec")
        return
    registered = ssh(host, "sudo test -s /var/lib/gitea-runner/.runner", check=False).returncode == 0
    script = app_script(host, "gitea-runner")   # always this host's own runner, never the source's
    if registered:
        print(f"{host} is registered locally; install + up only")
        if apply:
            ssh(host, f"{script} install up", stream=True)
        return
    delete_runner_entry(host, apply)
    print(f"{script} install, register (instance token from {GITEA_TOKEN_HOST}, stdin only), up")
    if not apply:
        return
    ssh(host, f"{script} install", stream=True)
    r = ssh(GITEA_TOKEN_HOST, "docker exec -u git gitea gitea actions generate-runner-token", timeout=120)
    token = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if not token:
        raise Fail("no registration token from Gitea")
    ssh(host, f"{script} register", stdin=token + "\n")
    token = ""
    ssh(host, f"{script} up", stream=True)


# ---------------------------------------------------------------- verify and plan

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
    try:
        check("deploy token reads GitLab", bool(check_token(host)))
    except Fail as e:
        check("deploy token reads GitLab", False, str(e))
    sha, drift = scripts_drift(spec)
    check(f"~/scripts matches GitLab master {sha[:12]}", not drift,
          f"{len(drift)} differ: {', '.join(drift[:5])}" if drift else "")
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
        if live.get("node") != vm["node"]:
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
    return 0


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("host")
    ap.add_argument("action", choices=["plan", "build", "verify", "token", "scripts-check", "secrets", "destroy"])
    ap.add_argument("args", nargs="*", help="for the secrets action: check, push or install, then optional VAR names")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--from", dest="start", choices=PHASES)
    ap.add_argument("--only", choices=PHASES)
    ap.add_argument("--recreate", action="store_true")
    ap.add_argument("--confirm")
    a = ap.parse_args()
    try:
        spec = load_spec(a.host)
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
            if not a.args or a.args[0] not in ("check", "push", "install"):
                raise Fail("secrets needs check|push|install")
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
