#!/usr/bin/env python3
"""Build, rebuild and verify a d0N Docker host from its spec, from the workstation.

asyla hub decisions/host-build-and-recovery.md: a rebuild must reproduce everything a host runs,
from nothing but GitLab (this repo, its CI/CD variables), the NAS backups and the hypervisor.

Usage:
  build_host.py HOST plan                      # read-only: spec, live VM, gaps
  build_host.py HOST build [--apply] [--from PHASE] [--only PHASE] [--recreate [--confirm HOST]]
  build_host.py HOST verify                    # read-only
  build_host.py HOST secrets check|push|install [--apply] [VAR ...]
  build_host.py HOST destroy --apply [--confirm HOST]

Build phases, in order (each is safe to re-run):
  vm         create the VM from HOST/host.toml (skipped when it exists; --recreate destroys it
             first: allowed freely only for a spec with disposable = true, else needs --confirm HOST)
  bootstrap  deploy token to /etc/asyla/asyla-hosts.env, then the host's update_scripts.sh
             (from GitLab master, the same file the host will keep running)
  disk       data disk -> /mnt/docker (docker/setup/data_disk.sh; never formats a disk with data)
  secrets    every [[secret]] from GitLab CI/CD variables to its path
  setup      HOST/setup/<step> for each [setup].steps, as root
  restore    `<app>.sh restore` for each app whose data is empty (from its NAS mirror)
  apps       each app's start commands (default: up), in spec order
  external   other repos' deploy commands from the workstation; `manual` entries are listed
  runner     Gitea runner: delete this host's stale entry, install, register, up
  verify     mounts, every app's verify (or running containers), runner online

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
    for s in spec.get("secret", []):
        if not s.get("var", "").replace("_", "").isalnum():
            raise Fail(f"{path}: bad secret var {s.get('var')!r}")
    return spec


def app_script(host: str, app: str) -> str:
    return f"~/scripts/{host}/apps/{app}/{app}.sh"


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
    ssh(host, "cloud-init status --wait >/dev/null; test -f /var/lib/cloud/instance/asyla-vendor-done", timeout=1800,
        check=False, stream=False)
    r = ssh(host, "cloud-init status; id docker", check=False)
    print(r.stdout.strip())


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


def phase_bootstrap(spec: dict, apply: bool) -> None:
    host = spec["host"]
    user, token = need("ASYLA_HOSTS_DEPLOY_USER"), need("ASYLA_HOSTS_DEPLOY_TOKEN")
    print(f"install {DEPLOY_ENV} (root 0600; value ...{token[-4:]}), then {host}/update_scripts.sh from GitLab master")
    script = master_file(f"{host}/update_scripts.sh")
    if not apply:
        return
    body = f"ASYLA_HOSTS_DEPLOY_USER={user}\nASYLA_HOSTS_DEPLOY_TOKEN={token}\n"
    ssh(host, f"sudo install -d -m 755 /etc/asyla && sudo sh -c 'umask 077; cat > {DEPLOY_ENV}.tmp' && "
              f"sudo chown root:root {DEPLOY_ENV}.tmp && sudo chmod 600 {DEPLOY_ENV}.tmp && "
              f"sudo mv {DEPLOY_ENV}.tmp {DEPLOY_ENV}", stdin=body)
    ssh(host, "sudo apt-get install -y -qq git curl rsync >/dev/null", timeout=900)
    ssh(host, "cat > /tmp/update_scripts.sh && sudo bash /tmp/update_scripts.sh; rc=$?; rm -f /tmp/update_scripts.sh; exit $rc",
        stdin=script, stream=True)


def phase_disk(spec: dict, apply: bool) -> None:
    host = spec["host"]
    if not spec["vm"].get("data_disk"):
        print("no data disk in spec; /mnt/docker stays on the root disk")
        if apply:
            ssh(host, "sudo install -d -o docker -g asyla /mnt/docker")
        return
    print("data disk scsi2 -> /mnt/docker")
    if apply:
        ssh(host, "sudo ~/scripts/docker/setup/data_disk.sh scsi2 /mnt/docker docker:asyla", stream=True)


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


def secrets_cmd(spec: dict, action: str, apply: bool, only: list[str]) -> int:
    host, bad = spec["host"], 0
    items = [s for s in spec.get("secret", []) if not only or s["var"] in only]
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

def app_has(host: str, app: str, switch: str) -> bool:
    r = ssh(host, f"grep -qE '^[[:space:]]+([a-z_|-]+\\|)?{switch}(\\|[a-z_|-]+)?\\)' {app_script(host, app)}", check=False)
    return r.returncode == 0


def phase_restore(spec: dict, apply: bool) -> None:
    host = spec["host"]
    for a in spec.get("app", []):
        name = a["name"]
        if not app_has(host, name, "restore"):
            print(f"restore {name}: GAP - {name}.sh has no restore")
            continue
        print(f"restore {name} (skipped by the app when its data dir is not empty)")
        if apply:
            r = ssh(host, f"{app_script(host, name)} restore", check=False, stream=True)
            if r.returncode != 0:
                print(f"  restore {name}: exit {r.returncode} (data present, or no complete backup); continuing")


def phase_apps(spec: dict, apply: bool) -> None:
    host = spec["host"]
    for a in spec.get("app", []):
        cmds = a.get("start", ["up"])
        print(f"start {a['name']}: {' '.join(cmds)}")
        if apply:
            ssh(host, f"{app_script(host, a['name'])} {' '.join(cmds)}", stream=True, timeout=3600)


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
    script = app_script(host, "gitea-runner")
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
    mounts = out[2].split()
    for m in ["/mnt/nas/data1/docker", "/mnt/nas/data2/docker"] + (["/mnt/docker"] if spec["vm"].get("data_disk") else []):
        check(f"mount {m}", m in mounts)
    if "smb.sh" in spec.get("setup", {}).get("steps", []):
        check("mount /mnt/nas/data1/media", "/mnt/nas/data1/media" in mounts)
    check("deploy token file", ssh(host, f"sudo test -s {DEPLOY_ENV}", check=False).returncode == 0)
    for a in spec.get("app", []):
        name = a["name"]
        if a.get("verify"):
            r = ssh(host, f"{app_script(host, name)} {' '.join(a['verify'])}", check=False)
            check(f"app {name}", r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "")
        else:
            r = ssh(host, f"cd ~/scripts/{host}/apps/{name} && docker compose ls --format json", check=False)
            running = [p for p in json.loads(r.stdout or "[]") if "running" in p.get("Status", "")
                       and f"/apps/{name}/" in p.get("ConfigFiles", "")]
            check(f"app {name} running", bool(running))
        check(f"app {name} restore", app_has(host, name, "restore"), "" if app_has(host, name, "restore") else "no restore switch")
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
    print(f"  secrets: {len(spec.get('secret', []))}; apps: {', '.join(a['name'] for a in spec.get('app', []))}")
    gaps = sum(1 for e in spec.get("external", []) if e.get("manual"))
    print(f"  externals: {len(spec.get('external', []))} ({gaps} manual)")
    return 0


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("host")
    ap.add_argument("action", choices=["plan", "build", "verify", "secrets", "destroy"])
    ap.add_argument("args", nargs="*", help="secrets: check|push|install [VAR ...]")
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
                if secrets_cmd(spec, "install", a.apply, []):
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
