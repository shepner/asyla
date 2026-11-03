#!/usr/bin/env python3
# Vendored unchanged by asyla from theOrg observability scripts/loki_clients.py at 2144f83c3ec978663d3cb544e743ae8006471a0a
# (only these two comment lines added). Update by re-vendoring at the new OBSERVABILITY_TAG.
"""Accounts at Loki's gateway (DEPLOY.md, "Loki gateway"; loki-clients.toml lists them).

    loki_clients.py provision        create each listed account's password if it has none
    loki_clients.py check-senders    every listed container on this host holds the stored password
    loki_clients.py render           write the gateway's verifier files from the stored passwords
    loki_clients.py verify           prove the gateway refuses and admits what it should
    loki_clients.py github-env --account NAME --var VAR
                                     hand one account's stored password to the job's later steps
                                     ($GITHUB_ENV), masked in the job log

Each subcommand takes --registry and --passwords-dir (env LOKI_CLIENTS_REGISTRY and
LOKI_CLIENTS_PASSWORDS_DIR), after the subcommand's name.

The registry is loki-clients.toml beside this script (theOrg's accounts) unless --registry names
another file in the same format: a deployer elsewhere lists its own accounts there.

The passwords live in one of two places:

- OpenBao (the default; theOrg's deploy.yml and loki-clients.yml): at
  <LOKI_CLIENTS_KV_PREFIX>/<name>, default secret/v2/observability/loki-clients/<name> (fields
  username, password), generated once and never overwritten (`kv put -cas=0`). Its user reads it
  from there at deploy; nothing keeps a copy in a file.
- A directory (--passwords-dir), for a deployer without theOrg's OpenBao: one file per account,
  named <name>, holding exactly the password with no trailing newline. Then no OpenBao call is
  made by any subcommand and BAO_ROOT_TOKEN is not read. `provision` creates each missing file
  (O_CREAT|O_EXCL, mode 0600) and never overwrites one. The directory itself must be closed to
  group and others (0700, say): one that is not is refused before any file in it is read or
  made. A value shorter than 32 characters, or
  holding a control character (a newline included), a double quote or a backslash, is refused:
  the fast hash below is safe only for high-entropy values, and `verify` hands the value to curl
  inside a quoted config line.

Either way a new password is 32 random bytes (secrets.token_urlsafe). The gateway holds only
SHA-512-crypt verifiers (`openssl passwd -6`, run in the gateway image), in push.htpasswd and
query.htpasswd on the loki-gateway-auth volume, readable by nginx's user alone. A fast salted hash
is enough here because these are 256-bit random values, not human passwords, and nginx checks one
on every request. That argument holds only for such values, which is why the directory source
refuses a short one: a password a person chose would want a slow hash instead.

`check-senders` is the ordering guard. Loki drops a push the gateway refuses (a 4xx is not
retried), so deploy.yml runs it before the gateway is recreated: a listed container that runs on
this host without its credential, or with one that differs from the stored one, fails the deploy
while the stack is still up. A container not on this host is skipped and said so. A client is
checked in its `env` (`docker inspect`), or, when the registry gives it a `file`, in that file
inside the running container: `docker exec -i <container> sh -c 'cmp -s - "$1"' sh <file>`, with
the stored value on stdin, so it never leaves the container's side nor enters argv.

`verify` needs the accounts observability-check-push and observability-check-query in the
registry, one per scope, so each proves the other is refused.

No value is ever printed, put in argv or written outside the store and the verifier volume (and,
for github-env, the job's own $GITHUB_ENV file, after an `::add-mask::` directive that the runner
consumes and does not show): the
vault token goes to docker by name (`-e BAO_TOKEN`), passwords go on stdin (`bao kv put ... -`,
`openssl passwd -stdin`, `curl -K -`, `cmp -s -`), and bao's stderr is matched, never shown.

Env: LOKI_CLIENTS_REGISTRY; LOKI_CLIENTS_PASSWORDS_DIR; and for OpenBao BAO_ROOT_TOKEN,
OPENBAO_CONTAINER (default openbao-1) and LOKI_CLIENTS_KV_PREFIX (default
secret/v2/observability/loki-clients). COMPOSE_PROJECT_NAME (default observability) names
render's default volume.
"""
from __future__ import annotations

import argparse
import hmac
import json
import os
import posixpath
import re
import secrets
import stat
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "loki-clients.toml"
KV_PREFIX = "secret/v2/observability/loki-clients"
# A vault path: segments of a safe alphabet, no empty, "." or ".." segment.
_KV_SEGMENT = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*")
# The directory source refuses anything shorter (module docstring: the fast hash needs entropy).
MIN_PASSWORD_LEN = 32
CHECK_ACCOUNTS = ("observability-check-push", "observability-check-query")
SCOPES = ("push", "query")
DEFAULT_ENV = {"push": "LOKI_PUSH_PASSWORD", "query": "LOKI_QUERY_PASSWORD"}
FILES = {"push": "push.htpasswd", "query": "query.htpasswd"}
# nginx's worker user in nginx:alpine; the verifier files are its alone.
NGINX_UID = 101


class Failed(Exception):
    """A step that cannot go on; the message names what and why, never a value."""


@dataclass(frozen=True)
class Client:
    name: str
    scopes: tuple[str, ...]
    container: str | None
    env: str
    # Where the container holds it instead of `env`: an absolute path inside the container.
    file: str | None = None

    @property
    def kv_path(self) -> str:
        return f"{kv_prefix()}/{self.name}"


def kv_prefix() -> str:
    """OpenBao's path for the records: LOKI_CLIENTS_KV_PREFIX, default KV_PREFIX."""
    prefix = os.environ.get("LOKI_CLIENTS_KV_PREFIX") or KV_PREFIX
    segments = prefix.split("/")
    if not all(_KV_SEGMENT.fullmatch(s) and s != ".." for s in segments):
        raise Failed("LOKI_CLIENTS_KV_PREFIX must be a vault path: segments of letters, digits, "
                     "-, _ or ., separated by single /, with no leading or trailing /")
    return prefix


def load_clients(path: Path = REGISTRY) -> list[Client]:
    try:
        data = tomllib.loads(path.read_text())
    except OSError as e:
        raise Failed(f"{path}: cannot read the registry ({e.strerror or e})") from None
    except tomllib.TOMLDecodeError as e:
        raise Failed(f"{path}: not valid TOML ({e})") from None
    out = []
    for name, spec in sorted((data.get("clients") or {}).items()):
        # A name goes into an htpasswd line and a vault path, so it is kept to a safe alphabet.
        if not name or not all(c.isalnum() or c in "-_" for c in name):
            raise Failed(f"{path.name}: client name {name!r} must be letters, digits, - or _")
        scopes = tuple(spec.get("scope") or ())
        if not scopes or any(s not in SCOPES for s in scopes) or len(set(scopes)) != len(scopes):
            raise Failed(f"{path.name}: {name}: scope must be a list of {SCOPES}")
        env = spec.get("env") or DEFAULT_ENV["push" if "push" in scopes else "query"]
        file = spec.get("file")
        if file is not None:
            # It becomes an argument to sh inside the container, so: absolute, normalised, one line.
            if (not isinstance(file, str) or not file.startswith("/") or "\0" in file
                    or "\n" in file or posixpath.normpath(file) != file):
                raise Failed(f"{path.name}: {name}: file must be an absolute, normalised path")
            if not spec.get("container"):
                raise Failed(f"{path.name}: {name}: file needs the container that holds it")
            if spec.get("env"):
                raise Failed(f"{path.name}: {name}: give env or file, not both")
        out.append(Client(name, scopes, spec.get("container") or None, env, file))
    if not out:
        raise Failed(f"{path.name}: no clients")
    return out


def log(msg: str) -> None:
    print(msg, flush=True)


# --- OpenBao ---------------------------------------------------------------------------------

def _bao(args: list[str], stdin: str = "") -> subprocess.CompletedProcess:
    tok = os.environ.get("BAO_ROOT_TOKEN") or ""
    if not tok:
        raise Failed("BAO_ROOT_TOKEN is not set")
    container = os.environ.get("OPENBAO_CONTAINER") or "openbao-1"
    env = dict(os.environ, BAO_TOKEN=tok)
    return subprocess.run(
        ["docker", "exec", "-i", "-e", "BAO_TOKEN", "-e", "BAO_SKIP_VERIFY=true", container,
         "bao", *args[:2], "-address=https://127.0.0.1:8200", *args[2:]],
        input=stdin, capture_output=True, text=True, env=env, timeout=60,
    )


def _why(proc: subprocess.CompletedProcess) -> str:
    err = proc.stderr or ""
    if "No such container" in err or "is not running" in err:
        return "OpenBao's container is not running"
    if "Code: 403" in err:
        return "OpenBao refused the request (403)"
    if "connection refused" in err or "dial tcp" in err:
        return "OpenBao did not answer"
    return f"bao exit {proc.returncode}"


def read_record(c: Client) -> str | None:
    """The account's password, or None when nothing is stored. Failed for any other failure, so
    a vault that is down never reads as "absent" (provision would otherwise try to create)."""
    proc = _bao(["kv", "get", "-format=json", c.kv_path])
    if proc.returncode != 0:
        if "No value found" in (proc.stderr or ""):
            return None
        raise Failed(f"{c.kv_path}: {_why(proc)}")
    try:
        data = json.loads(proc.stdout)["data"]["data"]
    except (ValueError, KeyError, TypeError):
        raise Failed(f"{c.kv_path}: unexpected answer from OpenBao (not shown)") from None
    pw = data.get("password") if isinstance(data, dict) else None
    if not pw or data.get("username") != c.name:
        raise Failed(f"{c.kv_path}: the record has no password, or its username is not {c.name}")
    return pw


# --- the directory source --------------------------------------------------------------------

def password_file(c: Client, pwdir: Path) -> Path:
    return pwdir / c.name


def check_value(value: str, label: str) -> str:
    """The value, or Failed naming what is wrong with it (never the value itself)."""
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise Failed(f"{label}: holds a newline or another control character; it must hold "
                     "exactly the password (write it with printf %s, not echo)")
    if '"' in value or "\\" in value:
        raise Failed(f"{label}: holds a double quote or a backslash, which verify cannot pass to "
                     "curl; use a secrets.token_urlsafe(32) value")
    if len(value) < MIN_PASSWORD_LEN:
        raise Failed(f"{label}: shorter than {MIN_PASSWORD_LEN} characters; the gateway's fast "
                     "SHA-512-crypt hash is safe only for high-entropy values, so use a "
                     "secrets.token_urlsafe(32) value (`provision` makes one)")
    return value


def check_passwords_dir(pwdir: Path) -> None:
    """Failed unless pwdir is a directory that group and others cannot enter, list or write."""
    if not pwdir.is_dir():
        raise Failed(f"{pwdir}: the passwords directory does not exist or is not a directory")
    mode = stat.S_IMODE(pwdir.stat().st_mode)
    if mode & 0o077:
        raise Failed(f"{pwdir}: the passwords directory is mode {mode:04o}, open to group or "
                     f"others; make it 0700 (chmod 700 {pwdir}) and check who could have read it")


def read_password_file(c: Client, pwdir: Path) -> str | None:
    """The account's password from its file, or None when there is no file. Failed for anything
    else, so an unreadable file never reads as "absent" (provision would otherwise create)."""
    check_passwords_dir(pwdir)
    path = password_file(c, pwdir)
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Failed(f"{path}: cannot read ({e.strerror or type(e).__name__})") from None
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Failed(f"{path}: not UTF-8 text") from None
    return check_value(value, str(path))


def create_password_file(c: Client, pwdir: Path) -> None:
    """Write a new password to the account's file: created exclusively, mode 0600, never over an
    existing file (one that appears between the read and this is an error, not overwritten)."""
    path = password_file(c, pwdir)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags, 0o600)
    except FileExistsError:
        raise Failed(f"{path}: not created: it appeared meanwhile, and is not overwritten") from None
    except OSError as e:
        raise Failed(f"{path}: not created ({e.strerror or type(e).__name__})") from None
    try:
        os.fchmod(fd, 0o600)
        data = secrets.token_urlsafe(32).encode()
        if os.write(fd, data) != len(data):
            raise OSError("short write")
    except OSError as e:
        os.close(fd)
        path.unlink(missing_ok=True)
        raise Failed(f"{path}: not created ({e.strerror or e}); removed the partial file") from None
    os.close(fd)


# --- either source -----------------------------------------------------------------------------

def where(c: Client, pwdir: Path | None) -> str:
    """Where the account's password is kept, for messages."""
    return str(password_file(c, pwdir)) if pwdir else c.kv_path


def require_password(c: Client, pwdir: Path | None = None) -> str:
    if pwdir:
        pw = read_password_file(c, pwdir)
        if pw is None:
            raise Failed(f"{password_file(c, pwdir)}: no file; run `loki_clients.py provision` "
                         "with the same --passwords-dir")
        return pw
    pw = read_record(c)
    if pw is None:
        raise Failed(f"{c.kv_path}: no record; run `loki_clients.py provision` (loki-clients.yml)")
    return pw


def provision(clients: list[Client], pwdir: Path | None = None) -> None:
    if pwdir:
        for c in clients:
            if read_password_file(c, pwdir) is not None:
                log(f"{c.name}: exists")
                continue
            create_password_file(c, pwdir)
            log(f"{c.name}: created")
        return
    for c in clients:
        if read_record(c) is not None:
            log(f"{c.name}: exists")
            continue
        body = json.dumps({"username": c.name, "password": secrets.token_urlsafe(32)})
        proc = _bao(["kv", "put", "-cas=0", c.kv_path, "-"], stdin=body)
        if proc.returncode != 0:
            raise Failed(f"{c.kv_path}: not created: {_why(proc)}")
        log(f"{c.name}: created")


# --- check-senders ---------------------------------------------------------------------------

def _inspect(name: str, field: str):
    """One field of the container, parsed, or None when no such container exists on this host."""
    proc = subprocess.run(["docker", "inspect", "--format", "{{json " + field + "}}", name],
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        # Docker 29 says "error: no such object: <name>"; older daemons "No such container".
        err = (proc.stderr or "").lower()
        if "no such object" in err or "no such container" in err:
            return None
        raise Failed(f"docker inspect {name}: exit {proc.returncode}")
    return json.loads(proc.stdout)


def container_env(name: str) -> list[str] | None:
    """The container's environment, or None when no such container exists on this host."""
    env = _inspect(name, ".Config.Env")
    return None if env is None else (env or [])


def container_running(name: str) -> bool | None:
    """Whether the container runs, or None when no such container exists on this host."""
    running = _inspect(name, ".State.Running")
    return None if running is None else bool(running)


# The comparison runs in the container: OpenBao's value on stdin, the path as $1, nothing printed.
CMP_SCRIPT = 'cmp -s - "$1"'


def file_matches(container: str, path: str, value: str) -> str:
    """same | differs | missing, comparing `value` with the file at `path` inside `container`.

    `value` goes on stdin exactly, with no newline added: the senders write the file with
    `printf %s` (memory-system's vector-loki-credential.sh). cmp exits 0 when equal, 1 when they
    differ, 2 when it cannot read the file. docker exec's own failures exit 1 too, but with a
    message on stderr, which `cmp -s` never writes; that stderr is matched for presence only.
    """
    proc = subprocess.run(["docker", "exec", "-i", container, "sh", "-c", CMP_SCRIPT, "sh", path],
                          input=value, capture_output=True, text=True, timeout=60)
    if proc.returncode == 0:
        return "same"
    if proc.returncode == 1 and not (proc.stderr or "").strip():
        return "differs"
    if proc.returncode == 2:
        return "missing"
    raise Failed(f"docker exec {container}: exit {proc.returncode}; could not compare {path}")


def held_value(env: list[str], var: str) -> str | None:
    for item in env:
        k, sep, v = item.partition("=")
        if sep and k == var:
            return v
    return None


def check_senders(clients: list[Client], pwdir: Path | None = None) -> bool:
    ok = True
    for c in clients:
        if not c.container:
            continue
        if c.file:
            ok = _check_file(c, pwdir) and ok
            continue
        env = container_env(c.container)
        if env is None:
            log(f"{c.name}: {c.container} is not on this host; skipped")
            continue
        held = held_value(env, c.env)
        if not held:
            log(f"::error::{c.name}: {c.container} has no {c.env}; deploy its stack first "
                f"(it reads {where(c, pwdir)}), or the gateway refuses it and its logs are dropped")
            ok = False
        elif not hmac.compare_digest(held.encode(), require_password(c, pwdir).encode()):
            log(f"::error::{c.name}: {c.container}'s {c.env} is not the one in {where(c, pwdir)}; "
                "redeploy its stack first")
            ok = False
        else:
            log(f"{c.name}: {c.container} holds its credential")
    return ok


def _check_file(c: Client, pwdir: Path | None = None) -> bool:
    running = container_running(c.container)
    if running is None:
        log(f"{c.name}: {c.container} is not on this host; skipped")
        return True
    if not running:
        log(f"::error::{c.name}: {c.container} exists but is not running, so {c.file} in it "
            "cannot be read; start or redeploy its stack first")
        return False
    verdict = file_matches(c.container, c.file, require_password(c, pwdir))
    if verdict == "missing":
        log(f"::error::{c.name}: {c.file} is missing or unreadable in {c.container}; deploy its "
            f"stack first (it reads {where(c, pwdir)}), or the gateway refuses it and its logs are "
            "dropped")
        return False
    if verdict == "differs":
        log(f"::error::{c.name}: {c.container}'s {c.file} is not the one in {where(c, pwdir)}; "
            "redeploy its stack first")
        return False
    log(f"{c.name}: {c.container} holds its credential ({c.file})")
    return True


# --- render ----------------------------------------------------------------------------------

def compose_image(service: str = "loki-gateway") -> str:
    proc = subprocess.run(["docker", "compose", "config", "--format", "json"],
                          capture_output=True, text=True, timeout=120, cwd=ROOT)
    if proc.returncode != 0:
        raise Failed(f"docker compose config: exit {proc.returncode}")
    return json.loads(proc.stdout)["services"][service]["image"]


def sha512_crypt(password: str, image: str) -> str:
    proc = subprocess.run(
        ["docker", "run", "--rm", "-i", "--cpus", "0.5", "--memory", "64m", "--network", "none",
         "--entrypoint", "openssl", image,
         "passwd", "-6", "-stdin"],
        input=password + "\n", capture_output=True, text=True, timeout=120,
    )
    out = proc.stdout.strip()
    if proc.returncode != 0 or not out.startswith("$6$") or "\n" in out:
        raise Failed(f"openssl passwd in {image}: exit {proc.returncode}")
    return out


def htpasswd_files(clients: list[Client], passwords: dict[str, str], image: str) -> dict[str, str]:
    lines: dict[str, list[str]] = {s: [] for s in SCOPES}
    for c in clients:
        h = sha512_crypt(passwords[c.name], image)
        for s in c.scopes:
            lines[s].append(f"{c.name}:{h}")
    return {FILES[s]: "".join(f"{line}\n" for line in lines[s]) for s in SCOPES}


def write_volume(volume: str, files: dict[str, str], image: str) -> None:
    """Stage each file as <name>.new, then rename them all in one container: the gateway reads
    a file per request, so it sees either the old set or the new one."""
    for name, text in files.items():
        proc = subprocess.run(
            ["docker", "run", "--rm", "-i", "--cpus", "0.5", "--memory", "64m", "--network", "none",
             "-v", f"{volume}:/out",
             "--entrypoint", "sh", image, "-c",
             f'umask 077 && cat > "/out/$1.new" && chown {NGINX_UID}:{NGINX_UID} "/out/$1.new"',
             "sh", name],
            input=text, capture_output=True, text=True, timeout=120,
        )
        if proc.returncode != 0:
            raise Failed(f"staging {name} in {volume}: exit {proc.returncode}")
    proc = subprocess.run(
        ["docker", "run", "--rm", "--cpus", "0.5", "--memory", "64m", "--network", "none",
         "-v", f"{volume}:/out", "--entrypoint", "sh",
         image, "-c", 'cd /out && for n in "$@"; do mv "$n.new" "$n" || exit 1; done', "sh", *files],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        raise Failed(f"renaming the verifier files in {volume}: exit {proc.returncode}")


def render(clients: list[Client], volume: str, image: str, pwdir: Path | None = None) -> None:
    passwords = {c.name: require_password(c, pwdir) for c in clients}
    write_volume(volume, htpasswd_files(clients, passwords, image), image)
    for s in SCOPES:
        names = [c.name for c in clients if s in c.scopes]
        log(f"{FILES[s]}: {len(names)} account(s): {', '.join(names)}")


# --- verify ----------------------------------------------------------------------------------

# The network verify's curl containers join; None reaches the host's published port, as
# deploy.yml's other probes do (the integration test names its own network).
NETWORK: str | None = None


def curl(url: str, ca_volume: str | None, user: tuple[str, str] | None = None,
         method: str = "GET", data: str | None = None, body_out: bool = False,
         extra_hosts: tuple[str, ...] = ()) -> tuple[int, str]:
    """(HTTP status, body if asked) from a curl container. The account goes in curl's config
    on stdin. extra_hosts are `name:address` entries added to the container's /etc/hosts, for a
    name the network does not resolve (the default bridge has no DNS for container names)."""
    args = ["docker", "run", "--rm", "-i", "--cpus", "0.5", "--memory", "64m"]
    args += ["--network", NETWORK] if NETWORK else ["--add-host", "host.docker.internal:host-gateway"]
    for entry in extra_hosts:
        name, sep, address = entry.partition(":")
        if not (sep and name and address) or entry.startswith("-"):
            raise Failed(f"extra host {entry!r}: want name:address")
        args += ["--add-host", entry]
    tls = []
    if ca_volume:
        args += ["-v", f"{ca_volume}:/loki-ca:ro"]
        tls = ["--cacert", "/loki-ca/root_ca.crt"]
    args += ["curlimages/curl", "-sS", "--max-time", "20", "-K", "-", *tls, "-X", method,
             "-w", "\n%{http_code}", "-o", "-" if body_out else "/dev/null"]
    if data is not None:
        args += ["-H", "Content-Type: application/json", "--data-raw", data]
    args.append(url)
    config = f'user = "{user[0]}:{user[1]}"\n' if user else ""
    proc = subprocess.run(args, input=config, capture_output=True, text=True, timeout=120)
    body, _, code = proc.stdout.rpartition("\n")
    try:
        return int(code), body
    except ValueError:
        return 0, ""


def verify(base: str, ca_volume: str | None, push: tuple[str, str], query: tuple[str, str]) -> bool:
    nonce = secrets.token_hex(8)
    now_ns = time.time_ns()
    line = {"streams": [{"stream": {"forwarder": "loki-gateway-check"},
                         "values": [[str(now_ns), f"loki gateway check {nonce}"]]}]}
    q = f'{base}/loki/api/v1/query_range?query=%7Bforwarder%3D%22loki-gateway-check%22%7D&start={now_ns - 60 * 10**9}&end={now_ns + 60 * 10**9}&limit=50'
    labels = f"{base}/loki/api/v1/labels"
    pushed = f"{base}/loki/api/v1/push"
    body = json.dumps(line)
    checks = [
        ("/ready, no account", 200, lambda: curl(f"{base}/ready", ca_volume)),
        ("query, no account", 401, lambda: curl(labels, ca_volume)),
        ("push, no account", 401, lambda: curl(pushed, ca_volume, method="POST", data=body)),
        ("query, wrong password", 401, lambda: curl(labels, ca_volume, (query[0], "x" + query[1]))),
        ("push, push account", 204, lambda: curl(pushed, ca_volume, push, "POST", body)),
        ("query, push account", 401, lambda: curl(labels, ca_volume, push)),
        ("push, query account", 401, lambda: curl(pushed, ca_volume, query, "POST", body)),
        ("query, query account", 200, lambda: curl(labels, ca_volume, query)),
        ("/metrics, query account", 404, lambda: curl(f"{base}/metrics", ca_volume, query)),
        ("delete API, query account", 404,
         lambda: curl(f"{base}/loki/api/v1/delete?query=%7Ba%3D%22b%22%7D", ca_volume, query, "POST")),
    ]
    ok = True
    for name, want, run in checks:
        got, _ = run()
        mark = "ok" if got == want else "FAIL"
        ok &= got == want
        log(f"{mark:4} {name}: HTTP {got} (want {want})")
    # The pushed line must come back through the query account: the gateway forwards to Loki.
    found = False
    for _ in range(10):
        code, text = curl(q, ca_volume, query, body_out=True)
        if code == 200 and nonce in text:
            found = True
            break
        time.sleep(2)
    log(f"{'ok' if found else 'FAIL':4} the pushed line reads back through the gateway")
    return ok and found


# --- github-env ------------------------------------------------------------------------------

_ENV_NAME = re.compile(r"[A-Z_][A-Z0-9_]*")


def github_env(c: Client, var: str, pwdir: Path | None = None) -> None:
    """Append VAR=<the account's password> to $GITHUB_ENV, so a later step of the same job (the
    compose up) hands it to the container that uses it. The value is masked first."""
    target = os.environ.get("GITHUB_ENV") or ""
    if not target:
        raise Failed("GITHUB_ENV is not set: github-env runs inside a workflow job")
    if not _ENV_NAME.fullmatch(var):
        raise Failed(f"--var {var!r} must be an environment variable name (A-Z, 0-9, _)")
    pw = check_value(require_password(c, pwdir), c.name)
    print(f"::add-mask::{pw}", flush=True)
    with open(target, "a", encoding="utf-8") as f:
        f.write(f"{var}={pw}\n")
    log(f"{c.name}: handed to later steps as {var}")


# --- main ------------------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--registry", default=os.environ.get("LOKI_CLIENTS_REGISTRY") or None,
                        help="the accounts' TOML (env LOKI_CLIENTS_REGISTRY; default "
                             "loki-clients.toml in this repository)")
    common.add_argument("--passwords-dir",
                        default=os.environ.get("LOKI_CLIENTS_PASSWORDS_DIR") or None,
                        help="one file per account instead of OpenBao (env "
                             "LOKI_CLIENTS_PASSWORDS_DIR); no OpenBao call is made")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("provision", parents=[common])
    sub.add_parser("check-senders", parents=[common])
    r = sub.add_parser("render", parents=[common])
    r.add_argument("--volume", help="default <COMPOSE_PROJECT_NAME>_loki-gateway-auth")
    r.add_argument("--image", help="default: loki-gateway's image in the compose file")
    g = sub.add_parser("github-env", parents=[common])
    g.add_argument("--account", required=True, help="the registry entry, e.g. alert-relay")
    g.add_argument("--var", required=True, help="the variable later steps read, e.g. "
                                                "ALERT_RELAY_LOKI_PASSWORD")
    v = sub.add_parser("verify", parents=[common])
    v.add_argument("--url", default="https://host.docker.internal:3100")
    v.add_argument("--ca-volume", default=os.environ.get("LOKI_CA_VOLUME") or "loki-ca",
                   help="the root that signs the gateway's leaf; '' for an http URL")
    a = ap.parse_args(argv)
    pwdir = Path(a.passwords_dir) if a.passwords_dir else None
    try:
        clients = load_clients(Path(a.registry)) if a.registry else load_clients()
        if pwdir is None:
            kv_prefix()  # a bad LOKI_CLIENTS_KV_PREFIX fails before any vault call
        else:
            check_passwords_dir(pwdir)  # before any subcommand looks inside, or skips it
        if a.cmd == "provision":
            provision(clients, pwdir)
            return 0
        if a.cmd == "check-senders":
            return 0 if check_senders(clients, pwdir) else 1
        if a.cmd == "render":
            project = os.environ.get("COMPOSE_PROJECT_NAME") or "observability"
            render(clients, a.volume or f"{project}_loki-gateway-auth", a.image or compose_image(),
                   pwdir)
            return 0
        by_name = {c.name: c for c in clients}
        if a.cmd == "github-env":
            if a.account not in by_name:
                raise Failed(f"no account {a.account!r} in the registry")
            github_env(by_name[a.account], a.var, pwdir)
            return 0
        missing = [n for n in CHECK_ACCOUNTS if n not in by_name]
        if missing:
            raise Failed(f"verify needs the accounts {' and '.join(CHECK_ACCOUNTS)} in the "
                         f"registry (one per scope: push, query); missing: {', '.join(missing)}")
        push_c, query_c = (by_name[n] for n in CHECK_ACCOUNTS)
        ok = verify(a.url.rstrip("/"), a.ca_volume or None,
                    (push_c.name, require_password(push_c, pwdir)),
                    (query_c.name, require_password(query_c, pwdir)))
        return 0 if ok else 1
    except Failed as e:
        log(f"::error::{e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
