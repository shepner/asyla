#!/usr/bin/env python3
"""Deploy d06's observability stack with its components' vault identities (token-role mode).

Run on the workstation, from ~/local/asyla (asyla's hub token is the hub of the working directory):

    cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN -- \\
        python3 projects/asyla-hosts/d06/apps/observability/deploy_role.py [--dry-run|--revision-only]

1. images: `observability.sh images` on d06, with the registry pull token over SSH stdin
   (build_host.py's own helpers), before any mint: a wrapping token lives 300 s. It pulls every
   theOrg image, so a newer `latest` replaces the one d06 has (a third-party image, pinned by
   version, only when missing). The installed script must list theOrg images of the tag this
   repo's observability.sh names (`latest`, or a theOrg sha a commit pins), each on its REGISTRY.
2. revision: the theOrg observability commit the pulled images were built from. `observability.sh
   digests` on d06 (no token) gives the registry digest each theOrg image was pulled by (the same
   images as step 1); the provenance attestation the registry holds in that image index
   (buildkit's, from theOrg's publish-images) names its vcs.revision, with vcs.source theOrg's
   observability repo on the registry's host. Each digest must name exactly one commit, every
   theOrg image the same one (a pinned sha: that one), else exit 1, nothing minted. Every answer
   read by digest must hash to it. Not the OCI revision label: theOrg's images do not set it, and
   loki's carries its base image's.
3. the minting tool: theOrg observability's scripts/vault_identity.py and openbao.py at TOOL_REV
   (pinned here, not R: this code mints with asyla's hub token, so it runs only at a commit asyla
   reviewed), `git show` from the local clone (THEORG_CLONE) into a private temp dir (0700, code
   only, removed after), so the clone's own checkout is never moved. The clone is fetched first;
   R and TOOL_REV must be on its origin/main (`latest` is pushed from main only), and the two
   files must be the same at R as at TOOL_REV, else exit 1, nothing minted: review theOrg's change
   and bump TOOL_REV.
4. asyla's hub OpenBao token, in this process (secrets-vault's openbao_client.token(), the hub
   of the working directory), set only in the minting tool's environment as BAO_TOKEN;
   OPENBAO_TOKEN, VAULT_TOKEN and BAO_ROOT_TOKEN are removed from it. With
   OBSERVABILITY_DEPLOY_VAULT_TOKEN set (below), that token instead: no hub sign-in.
5. `vault_identity.py --token-role observability-d06` with one --identity per IDENTITIES line,
   which then runs `build_host.py d06 build --only apps --app observability --apply`: build_host
   sends each wrapping token to `observability.sh up` over SSH stdin, as a start_env_optional
   name of d06/host.toml. A mint that fails (a missing record, a policy that does not take) exits
   1 before anything starts, and so does this script. A start that fails may leave the stack
   partly recreated: this script says which of the two it was.
6. verify: the app's own `verify` on d06 (host.toml [[app]] verify, as build_host's verify phase
   runs it; `--only apps` skips that phase), with OBSERVABILITY_REVISION=<the revision> on its
   command line (not a secret), which it prints. It needs no token and waits for the first
   scrapes. A verify that fails makes this script exit 1.

Never prints, logs or writes a token or a value; no file holds one. --dry-run prints the plan from
local files only: it mints nothing and contacts nothing (no SSH, no vault, no fetch, no registry).
--revision-only runs steps 1-3 without writing the tool (the pull, the digests, the provenance,
origin/main and the TOOL_REV check), prints R and exits 0 (1 on any stop): no hub token, nothing
minted, nothing started.

Off the workstation (host-maintenance's redeploy job, in its runner container), from this
script's environment; unset, everything is as above:
  OBSERVABILITY_DEPLOY_VAULT_TOKEN=TOKEN  the vault token for step 4 (the job's own login), used
      as BAO_TOKEN instead of the hub sign-in. Taken out of this process's environment before
      anything runs, so no git, ssh or other child gets it under that name; set but empty, or
      more than one word: exit 1, nothing contacted. Every other step is unchanged: the same
      provenance, origin/main and TOOL_REV checks.
  OBSERVABILITY_DEPLOY_THEORG_CLONE=DIR   the theOrg observability clone (THEORG_CLONE), instead
      of ~/local/theOrg/projects/observability; it must have origin/main fetched, or fetchable
  OBSERVABILITY_DEPLOY_SECRETS_CLIENT=DIR secrets-vault's client/ (only for the hub sign-in),
      instead of ~/local/theOrg/projects/secrets-vault/client
  build_host.py's SSH override (BUILD_HOST_SSH_*, its docstring) reaches d06 for steps 1, 2, 5
  and 6: this script's SSH goes through build_host.ssh, and the start's build_host.py inherits it.

Turning a component off, or adding a record to one, is a one-line edit of IDENTITIES.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]                      # asyla-hosts
sys.path.insert(0, str(REPO / "scripts"))
import build_host  # noqa: E402

HOST, APP = "d06", "observability"
VAULT_ROLE = "observability-d06"            # secrets-vault policies/hubs.toml [token_roles.observability-d06]
HUB = "asyla"
KV = "secret/hubs/asyla"

# For a caller that is not the workstation (host-maintenance's redeploy job): the two theOrg paths,
# and a vault token it already holds, from these variables. Unset, the workstation's (docstring).
THEORG_CLONE_ENV = "OBSERVABILITY_DEPLOY_THEORG_CLONE"       # a clone of theOrg observability
SECRETS_CLIENT_ENV = "OBSERVABILITY_DEPLOY_SECRETS_CLIENT"   # secrets-vault's client/ directory
VAULT_TOKEN_ENV = "OBSERVABILITY_DEPLOY_VAULT_TOKEN"         # instead of the hub sign-in (step 4)


def env_path(name: str, default: Path) -> Path:
    """The directory variable NAME names, else DEFAULT (NAME unset or empty)."""
    return Path(os.environ[name]).expanduser() if os.environ.get(name) else default


THEORG_CLONE = env_path(THEORG_CLONE_ENV, Path.home() / "local/theOrg/projects/observability")
SECRETS_CLIENT = env_path(   # data/components.toml openbao
    SECRETS_CLIENT_ENV, Path.home() / "local/theOrg/projects/secrets-vault/client")
TOOL_FILES = ("vault_identity.py", "openbao.py")
# The theOrg observability commit whose minting tool (TOOL_FILES) asyla reviewed. It runs with
# asyla's hub token, so it is pinned apart from the images (which follow `latest`): the deploy runs
# the tool from here, and stops when R's copy differs. Bump it only after reading theOrg's change
# to scripts/vault_identity.py and scripts/openbao.py (f757911: both read 2026-11-03, the same at
# 7947763).
TOOL_REV = "f7579118fdac5d90101a5ec6698200ae2c9d836f"
CALLER_TOKENS = ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_ROOT_TOKEN")
TAG_LINE = re.compile(r'^OBSERVABILITY_TAG="\$\{OBSERVABILITY_TAG_OVERRIDE:-([0-9a-f]{7,40}|latest)\}"', re.M)
REGISTRY_LINE = re.compile(r'^REGISTRY="([a-z0-9][a-z0-9.-]*(?::[0-9]{1,5})?)"$', re.M)
THEORG_REF = re.compile(r"(^|/)theorg/", re.I)   # an image reference of theOrg's
IMAGES_TIMEOUT = 1800   # s: `images` pulls every theOrg image
DIGESTS_TIMEOUT = 120   # s: `digests` reads the local images only
GIT_TIMEOUT = 120       # s: per git command on the theOrg clone (a fetch included)
REGISTRY_TIMEOUT = 30   # s: per registry request
MAX_BODY = 4 * 1024 * 1024   # bytes: the most a registry answer may be (an index, a manifest, a provenance)
REGISTRY_USER = "theorg-registry"   # the pull token's user, as docker-credential-observability-env answers
THEORG_SOURCE = "/theorg/observability"   # a provenance vcs.source's path (case-insensitive, no .git)
REVISION = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
INDEX_ACCEPT = ", ".join(("application/vnd.oci.image.index.v1+json",
                          "application/vnd.docker.distribution.manifest.list.v2+json",
                          "application/vnd.oci.image.manifest.v1+json"))
VERIFY_TIMEOUT = 1800   # s: verify waits up to VERIFY_WAIT_S (300 s) per wait, a few in a row

# (component, the variable observability.sh up receives its wrapping token in, KV records): a
# record is a name under KV, or a full mount-first path when it starts with "secret/" (kv_path).
# Plain paths: vault_identity.py kv= takes no #field. One line per component.
IDENTITIES = [
    ("scrape-proxy", "SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN", ["home-assistant-prometheus-token"]),
    ("emporia-collector", "EMPORIA_OPENBAO_WRAPPED_TOKEN", ["emporia-username", "emporia-password"]),
    # The SMTP login, the Watchdog's ping URL (on: observability.sh ALERT_WATCHDOG_PING), the
    # Vikunja token for alert tasks in project 170 (user svc-alert-relay-d06's, outside KV:
    # secrets-vault#46, 5a75b93, grants token role observability-d06 read on it), the delivery
    # check's ping URL, and its Loki query account for log lines (own/loki-clients/alert-relay,
    # created by loki_accounts.py; compose.yml). The minting tool reads each record, so a record
    # not stored stops the deploy before the stack.
    ("alert-relay", "ALERT_RELAY_OPENBAO_WRAPPED_TOKEN",
     ["smtp-relay-username", "smtp-relay-password", "observability-watchdog-ping-url",
      "secret/v2/vikunja/alert-tokens/svc-alert-relay-d06", "observability-delivery-ping-url",
      "own/loki-clients/alert-relay"]),
]


class Stop(Exception):
    """A step failed: nothing after it runs."""


def stack_tag(script: Path) -> str:
    """The tag this repo's observability.sh runs (its OBSERVABILITY_TAG default): latest, or a theOrg
    observability commit a commit here pins."""
    m = TAG_LINE.search(script.read_text())
    if not m:
        raise Stop(f"{script}: no OBSERVABILITY_TAG=\"${{OBSERVABILITY_TAG_OVERRIDE:-latest|<sha>}}\" line")
    return m.group(1)


def stack_registry(script: Path) -> str:
    """The registry host[:port] this repo's observability.sh pulls theOrg's images from (its
    REGISTRY=): the only host a theOrg image may name, and the only one the pull token goes to."""
    m = REGISTRY_LINE.search(script.read_text())
    if not m:
        raise Stop(f"{script}: no REGISTRY=\"<host>\" line")
    return m.group(1)


def kv_path(record: str) -> str:
    """A record's mount-first KV path: as given when it starts with "secret/", else under KV."""
    return record if record.startswith("secret/") else f"{KV}/{record}"


def identity_args(identities: list) -> list[str]:
    """One --identity per component: component=, env=, and a plain-path kv= per record."""
    out = []
    for component, env, records in identities:
        if not records:
            raise Stop(f"{component}: no KV record; take its line out of IDENTITIES to turn it off")
        out += ["--identity", ",".join([f"component={component}", f"env={env}"]
                                       + [f"kv={kv_path(r)}" for r in records])]
    return out


def start_argv(spec: dict) -> list[str]:
    """build_host.py starting the app only (its phase: apps, or late when after_external)."""
    a = app_of(spec)
    phase = "late" if a.get("after_external") else "apps"
    return [sys.executable, str(REPO / "scripts/build_host.py"), HOST, "build", "--only", phase,
            "--app", APP, "--apply"]


def mint_argv(tool_dir: Path, identities: list, spec: dict) -> list[str]:
    """vault_identity.py in token-role mode, then (after --) the start."""
    return ([sys.executable, "-I", str(tool_dir / "vault_identity.py"), "--token-role", VAULT_ROLE]
            + identity_args(identities) + ["--"] + start_argv(spec))


def app_of(spec: dict) -> dict:
    for a in spec.get("app", []):
        if a["name"] == APP:
            return a
    raise Stop(f"{HOST}/host.toml has no [[app]] {APP}")


def check_spec(spec: dict, identities: list) -> None:
    """Each identity's env= is a start_env_optional name of the app (else build_host would not send
    it), no two identities share a component or an env=, and the app has a verify (run after the
    start)."""
    if not app_of(spec).get("verify"):
        raise Stop(f"{HOST}/host.toml [[app]] {APP} has no verify: nothing would check the start")
    optional = set(app_of(spec).get("start_env_optional", []))
    envs = [e for _, e, _ in identities]
    comps = [c for c, _, _ in identities]
    if len(set(envs)) != len(envs) or len(set(comps)) != len(comps):
        raise Stop("IDENTITIES: each component once, each with its own variable")
    unsent = [e for e in envs if e not in optional]
    if unsent:
        raise Stop(f"{HOST}/host.toml [[app]] {APP} start_env_optional lacks {', '.join(unsent)}: "
                   f"build_host would not send it")


def child_env(base: dict, signed_in: str, spec: dict) -> dict:
    """The minting tool's environment: the caller's, without any other vault token or a stale
    wrapping token, with the hub token as BAO_TOKEN."""
    drop = set(CALLER_TOKENS) | set(app_of(spec).get("start_env_optional", [])) | {"BAO_TOKEN", VAULT_TOKEN_ENV}
    env = {k: v for k, v in base.items() if k not in drop}
    env["BAO_TOKEN"] = signed_in
    return env


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    """git on the theOrg clone: never a prompt (a fetch that wants a login fails instead), at most
    GIT_TIMEOUT s, else one Stop line."""
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    try:
        return subprocess.run(["git", "-C", str(THEORG_CLONE), *args], capture_output=True, text=True,
                              check=check, env=env, timeout=GIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Stop(f"git {args[0]} in {THEORG_CLONE}: no end in {GIT_TIMEOUT} s; nothing minted")


MAIN = "refs/remotes/origin/main"


def has_tool(tag: str) -> bool:
    return all(git("cat-file", "-e", f"{tag}:scripts/{f}", check=False).returncode == 0 for f in TOOL_FILES)


def check_tool(rev: str) -> None:
    """After a fetch of origin: REV (the images' revision) and TOOL_REV are on the clone's
    origin/main (`latest` is pushed from main only), and the minting tool is the same at REV as at
    TOOL_REV, the commit asyla reviewed. Mints nothing, writes nothing."""
    if git("fetch", "--quiet", "origin", check=False).returncode != 0:
        print(f"  WARNING: git fetch origin in {THEORG_CLONE} failed; using the clone as it is")
    for what, c in (("R", rev), ("TOOL_REV", TOOL_REV)):
        if git("cat-file", "-e", f"{c}^{{commit}}", check=False).returncode != 0:
            raise Stop(f"{what} {c[:12]} is not in {THEORG_CLONE}; nothing minted")
        if git("merge-base", "--is-ancestor", c, MAIN, check=False).returncode != 0:
            raise Stop(f"{what} {c[:12]} is not on origin/main of {THEORG_CLONE}; nothing minted")
    if not has_tool(TOOL_REV):
        raise Stop(f"scripts/{' and '.join(TOOL_FILES)} at TOOL_REV {TOOL_REV[:12]} not in {THEORG_CLONE}; "
                   "nothing minted")
    d = git("diff", "--quiet", TOOL_REV, rev, "--", *(f"scripts/{f}" for f in TOOL_FILES), check=False)
    if d.returncode == 1:
        raise Stop(f"theOrg's minting tool changed between TOOL_REV {TOOL_REV[:12]} and R {rev[:12]}; review "
                   "it and bump TOOL_REV; nothing minted")
    if d.returncode != 0:
        raise Stop(f"git diff TOOL_REV R in {THEORG_CLONE}: exit {d.returncode}; nothing minted")


def unpack_tool(rev: str, into: Path) -> None:
    """vault_identity.py and openbao.py at TOOL_REV into INTO (code only), once check_tool(REV)
    passed: the tool at R is the same, and only code asyla reviewed runs with its hub token."""
    check_tool(rev)
    for f in TOOL_FILES:
        (into / f).write_text(git("show", f"{TOOL_REV}:scripts/{f}").stdout)
    if "--token-role" not in (into / "vault_identity.py").read_text():
        raise Stop(f"vault_identity.py at TOOL_REV {TOOL_REV[:12]} has no --token-role mode")


def redact(text: str, values: list[str]) -> str:
    for v in values:
        if v:
            text = text.replace(v, "...")
    return text


def theorg_images(refs: list[str], registry: str, what: str) -> list[str]:
    """The theOrg references of REFS, each on REGISTRY (else Stop: the pull token and the
    provenance reads go to that host only)."""
    theorg = [r for r in refs if THEORG_REF.search(r)]
    foreign = [r for r in theorg if split_ref(r)[0] != registry]
    if foreign:
        raise Stop(f"{what} names theOrg image(s) not on {registry}: {', '.join(sorted(foreign))[:300]}; "
                   "nothing minted")
    return theorg


def pull_images(spec: dict, tag: str, registry: str) -> list[str]:
    """`observability.sh images` on the host with the pull token over stdin (it pulls every theOrg
    image); its theOrg images must be on REGISTRY and of TAG (the installed script is this repo's).
    Returns them."""
    a = app_of(spec)
    host = spec["host"]
    pairs = build_host.app_env(spec, a, start=False)
    cmd, stdin = build_host.env_command(pairs, f"{build_host.app_script(spec['apps_tree'], APP)} images")
    try:
        r = build_host.ssh(host, cmd, stdin=stdin, check=False, timeout=IMAGES_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Stop(f"`{APP}.sh images` on {host}: no end in {IMAGES_TIMEOUT} s; nothing minted, nothing started")
    if r.returncode != 0:
        tail = redact(r.stderr or "", [v for _, v in pairs])[-2000:]   # redact, then cut: no half value
        sys.stderr.write(tail + ("\n" if tail and not tail.endswith("\n") else ""))
        raise Stop(f"`{APP}.sh images` on {host}: exit {r.returncode}; nothing minted, nothing started")
    images = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    theorg = theorg_images(images, registry, f"{host}'s `{APP}.sh images`")
    stale = [i for i in theorg if not i.endswith(f":{tag}")]
    if not theorg or stale:
        raise Stop(f"{host}'s installed {APP}.sh lists {len(theorg)} theOrg image(s), {len(stale)} not of "
                   f"{tag[:12]}: {host}'s scripts tree is not this repo's master; nothing minted. Merge this "
                   f"change to master, then install master on {host}: {bootstrap_hint(host)}; then run this again")
    print(f"  {len(images)} image(s) ready, {len(theorg)} theOrg image(s) of {tag[:12]} pulled from {registry}")
    return theorg


def image_name(ref: str) -> str:
    return ref.rsplit("/", 1)[-1]


def split_ref(ref: str) -> tuple[str, str]:
    """(registry host, repository) of an image reference HOST/REPO[:TAG]; ("", REF) without a host."""
    if "/" not in ref:
        return "", ref
    host, rest = ref.split("/", 1)
    return host, (rest.rsplit(":", 1)[0] if ":" in rest.rsplit("/", 1)[-1] else rest)


def image_digests(spec: dict, registry: str) -> dict[str, list[str]]:
    """Each theOrg image of the stack with the registry digest(s) the host pulled it by
    (`observability.sh digests`, no token): {reference: [sha256:<64 hex>, ...]}, [] for none ("-").
    Every theOrg image on REGISTRY; any other digest form stops."""
    host, script = spec["host"], build_host.app_script(spec["apps_tree"], APP)
    try:
        r = build_host.ssh(host, f"{script} digests", check=False, timeout=DIGESTS_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Stop(f"`{APP}.sh digests` on {host}: no end in {DIGESTS_TIMEOUT} s; nothing minted, nothing started")
    if r.returncode != 0:
        tail = (r.stderr or "")[-2000:]
        sys.stderr.write(tail + ("\n" if tail and not tail.endswith("\n") else ""))
        raise Stop(f"`{APP}.sh digests` on {host}: exit {r.returncode}; nothing minted, nothing started")
    out = {}
    lines = [ln.split() for ln in r.stdout.splitlines() if ln.strip()]
    for f in lines:
        if f[0] not in theorg_images([f[0]], registry, f"`{APP}.sh digests` on {host}"):
            continue
        ds = [] if f[1:] == ["-"] else f[1:]
        odd = [d for d in ds if not DIGEST.fullmatch(d)]
        if not f[1:] or odd:
            raise Stop(f"`{APP}.sh digests` on {host}: {image_name(f[0])}: "
                       f"{(odd[0][:24] if odd else 'nothing')!r} is not sha256:<64 hex>; nothing minted")
        out[f[0]] = ds
    if not out:
        raise Stop(f"`{APP}.sh digests` on {host} listed no theOrg image; nothing minted")
    return out


def origin(url: str) -> tuple[str, int]:
    """(host name, port) of an https URL, port 443 when it names none: what "the same host" means
    for the Authorization header."""
    u = urllib.parse.urlsplit(url)
    try:
        port = u.port
    except ValueError:
        raise Stop(f"{u.hostname}: a URL with a port that is not a number; nothing minted")
    return (u.hostname or "", port or 443)


class AuthStaysRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect keeps the Authorization header only to https on the same host and port; to any
    other it goes without it, and a redirect off https is refused. urllib's own handler copies
    every header to wherever the redirect points."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is None:
            return None
        to, was = urllib.parse.urlsplit(new.full_url), urllib.parse.urlsplit(req.full_url)
        if to.scheme != "https":
            raise Stop(f"{was.hostname}: a redirect off https ({to.scheme or 'no scheme'}); nothing minted")
        if origin(new.full_url) != origin(req.full_url):
            new.remove_header("Authorization")
        return new


OPENER = urllib.request.build_opener(AuthStaysRedirect)


def read_capped(r, url: str) -> bytes:
    """A response body of at most MAX_BODY bytes, else Stop (nothing larger is read)."""
    body = r.read(MAX_BODY + 1)
    if len(body) > MAX_BODY:
        raise Stop(f"{urllib.parse.urlsplit(url).hostname}: an answer over {MAX_BODY // (1024 * 1024)} MiB; "
                   "nothing minted")
    return body


def http_get(url: str, headers: dict) -> tuple[int, dict, bytes]:
    """(status, lower-cased headers, body) of a GET; an HTTP error status is returned, not raised.
    Only https (a redirect too: AuthStaysRedirect); a body over MAX_BODY stops."""
    if urllib.parse.urlsplit(url).scheme != "https":
        raise Stop(f"{urllib.parse.urlsplit(url).hostname}: not https; nothing minted")
    try:
        with OPENER.open(urllib.request.Request(url, headers=headers), timeout=REGISTRY_TIMEOUT) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, read_capped(r, url)
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in (e.headers or {}).items()}, b""
    except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
        raise Stop(f"{urllib.parse.urlsplit(url).hostname}: {getattr(e, 'reason', None) or type(e).__name__}; "
                   "nothing minted")


class Registry:
    """Read-only access to one registry: the pull token (Basic) only to its own token realm, https on
    the same host, for a pull-scoped bearer token per repository; the bearer only to that host."""

    def __init__(self, host: str, secret: str):
        self.host, self.tokens, self.realm, self.service = host, {}, "", ""
        self.basic = base64.b64encode(f"{REGISTRY_USER}:{secret}".encode()).decode()

    def bearer(self, repo: str) -> str:
        if repo not in self.tokens:
            if not self.realm:
                st, h, _ = http_get(f"https://{self.host}/v2/", {})
                auth = h.get("www-authenticate", "")
                ch = dict(re.findall(r'(\w+)="([^"]*)"', auth))
                realm = urllib.parse.urlsplit(ch.get("realm", ""))
                if (st != 401 or not auth.lower().startswith("bearer ") or realm.scheme != "https"
                        or origin(realm.geturl()) != origin(f"https://{self.host}")):
                    raise Stop(f"{self.host}/v2/: HTTP {st}, no Bearer realm on {self.host} over https; "
                               "the pull token is not sent; nothing minted")
                self.realm, self.service = ch["realm"], ch.get("service", "")
            q = urllib.parse.urlencode({"service": self.service, "scope": f"repository:{repo}:pull"})
            st, _, body = http_get(f"{self.realm}{'&' if '?' in self.realm else '?'}{q}",
                                   {"Authorization": f"Basic {self.basic}"})
            if st != 200:
                raise Stop(f"{self.host}: a pull token for {repo}: HTTP {st}; nothing minted")
            answer = json.loads(body)
            self.tokens[repo] = answer.get("token") or answer["access_token"]
        return self.tokens[repo]

    def get(self, repo: str, kind: str, ref: str) -> dict:
        """A manifest or blob by its digest REF, whose body must hash to REF (content-addressed:
        what any host on the way answers cannot stand in for it)."""
        if not isinstance(ref, str) or not DIGEST.fullmatch(ref):
            raise Stop(f"{self.host}/{repo} {kind}: {str(ref)[:24]!r} is not sha256:<64 hex>; nothing minted")
        h = {"Authorization": f"Bearer {self.bearer(repo)}", "Accept": INDEX_ACCEPT}
        st, _, body = http_get(f"https://{self.host}/v2/{repo}/{kind}/{ref}", h)
        if st != 200:
            raise Stop(f"{self.host}/{repo} {kind} {ref[:19]}: HTTP {st}; nothing minted")
        if "sha256:" + hashlib.sha256(body).hexdigest() != ref:
            raise Stop(f"{self.host}/{repo} {kind} {ref[:19]}: the answer does not hash to its digest; nothing minted")
        return json.loads(body)


def provenance_vcs(predicate: dict) -> dict:
    """buildkit's vcs record in a SLSA provenance predicate (v1, or v0.2), or {}."""
    v1 = ((predicate.get("runDetails") or {}).get("metadata") or {}).get("buildkit_metadata") or {}
    v02 = (predicate.get("metadata") or {}).get("https://mobyproject.org/buildkit@v1#metadata") or {}
    vcs = v1.get("vcs") or v02.get("vcs") or {}
    return vcs if isinstance(vcs, dict) else {}


def revisions_of(reg: Registry, repo: str, digest: str) -> set[str]:
    """The theOrg commits the provenance attestations of image index DIGEST name: one per
    attestation, "" for one that names none of theOrg observability's (on the registry's host).
    Empty: no attestation."""
    revs, forge = set(), origin(f"https://{reg.host}")[0]
    for m in reg.get(repo, "manifests", digest).get("manifests", []):
        if (m.get("annotations") or {}).get("vnd.docker.reference.type") != "attestation-manifest":
            continue
        layers = [la for la in reg.get(repo, "manifests", m["digest"]).get("layers", [])
                  if "slsa.dev/provenance" in (la.get("annotations") or {}).get("in-toto.io/predicate-type", "")]
        if not layers:
            revs.add("")
        for la in layers:
            vcs = provenance_vcs(reg.get(repo, "blobs", la["digest"]).get("predicate") or {})
            src = urllib.parse.urlsplit(str(vcs.get("source", "")).lower())
            rev = str(vcs.get("revision", ""))
            ok = (src.scheme == "https" and src.hostname == forge
                  and src.path.rstrip("/").removesuffix(".git") == THEORG_SOURCE)
            revs.add(rev if ok and REVISION.fullmatch(rev) else "")
    return revs


def stack_revision(spec: dict, tag: str, registry: str, pulled: list[str]) -> str:
    """The one theOrg observability commit every pulled theOrg image was built from (docstring,
    step 2): `digests` must list the theOrg images `images` pulled (PULLED), all on REGISTRY, and
    each digest's provenance must name exactly one commit, the same for all. A pinned TAG must be
    that commit."""
    digests = image_digests(spec, registry)
    if sorted(digests) != sorted(pulled):
        raise Stop(f"`{APP}.sh digests` on {spec['host']} lists other theOrg images than `images` pulled "
                   f"({len(digests)} vs {len(pulled)}); nothing minted")
    secret = build_host.from_env(app_of(spec)["pull_token_env"], f"[[app]] {APP} pull_token_env")
    reg, found, bad = Registry(registry, secret), {}, []
    try:
        for ref, ds in sorted(digests.items()):
            if not ds:
                bad.append(f"{image_name(ref)}: no registry digest on {spec['host']}")
                continue
            per = [revisions_of(reg, split_ref(ref)[1], d) for d in ds]
            named = set().union(*per) - {""}
            unread = sum(1 for r in per if not r or "" in r)   # no attestation, or one naming no theOrg commit
            if unread:
                bad.append(f"{image_name(ref)}: no theOrg revision in its provenance ({unread} of {len(ds)} digest(s))")
            elif len(named) != 1:
                bad.append(f"{image_name(ref)}: revisions {', '.join(sorted(r[:12] for r in named))}")
            else:
                found[ref] = named.pop()
    except (ValueError, KeyError, TypeError, AttributeError) as e:
        raise Stop(f"the registry's answer was not understood ({type(e).__name__}); nothing minted")
    if bad:
        raise Stop(f"the theOrg images' build revision cannot be read: {'; '.join(bad)}; nothing minted")
    commits = sorted(set(found.values()))
    if len(commits) != 1:
        raise Stop("the theOrg images were built from different commits: "
                   + "; ".join(f"{image_name(r)} {c[:12]}" for r, c in sorted(found.items()))
                   + "; nothing minted (a publish may have been running: run this again after it ends)")
    rev = commits[0]
    if tag != "latest" and not rev.startswith(tag):
        raise Stop(f"the images of {tag[:12]} name {rev[:12]} as their build revision; nothing minted")
    print(f"  theOrg observability revision {rev} (the provenance of the {len(found)} pulled theOrg "
          f"images, each read by its registry digest)")
    return rev


def bootstrap_hint(host: str) -> str:
    """The command that installs master's scripts tree on HOST (its update_scripts.sh from GitLab
    master, the deploy token over SSH stdin: build_host.py phase_bootstrap)."""
    return (f"cd ~/local/asyla && python3 core/tools/credentials.py exec ASYLA_HOSTS_DEPLOY_USER "
            f"ASYLA_HOSTS_DEPLOY_TOKEN -- python3 projects/asyla-hosts/scripts/build_host.py {host} build "
            f"--only bootstrap --apply")


def run_start(argv: list[str], env: dict) -> tuple[int, bool]:
    """The mint and then the start (ARGV), their stdout passed through line by line. Returns
    (exit, started). started is False when vault_identity.py printed an `::error::` line: it does
    so for every failure, before it runs the start ("Any failure exits 1 before the command runs",
    its header at the tag). build_host.py and observability.sh print no `::error::` line."""
    said_error = False
    env = {**env, "PYTHONUNBUFFERED": "1"}   # build_host's lines as they come (vault_identity.py flushes)
    with subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, text=True) as p:
        for line in p.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            said_error = said_error or line.startswith("::error::")
    return p.returncode, not said_error


def verify_app(spec: dict, rev: str = "") -> None:
    """The app's own verify on the host, as build_host.py's verify phase runs it (no token, its
    output shown as it comes), with OBSERVABILITY_REVISION=REV (a sha, not a secret) when given.
    observability.sh verify waits for the services and the first scrapes, up to its VERIFY_WAIT_S
    per wait."""
    a, host = app_of(spec), spec["host"]
    if rev and not REVISION.fullmatch(rev):
        raise Stop(f"revision {rev[:12]!r} is not a 40-hex sha")
    what = (f"OBSERVABILITY_REVISION={rev} " if rev else "") \
        + f"{build_host.app_script(spec['apps_tree'], APP)} {' '.join(a['verify'])}"
    try:
        r = build_host.ssh(host, what, check=False, stream=True, timeout=VERIFY_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Stop(f"`{what}` on {host}: no end in {VERIFY_TIMEOUT} s; the stack started, its state is "
                   f"not known: run it again on {host}")
    if r.returncode != 0:
        raise Stop(f"`{what}` on {host}: exit {r.returncode} (its lines are above): the stack started "
                   f"but does not verify")


def hub_sign_in() -> str:
    """asyla's hub token from secrets-vault's client, in this process only (never printed)."""
    sys.path.insert(0, str(SECRETS_CLIENT))
    import openbao_client as oc  # noqa: E402
    hub = oc.hub_name()
    if hub != HUB:
        raise Stop(f"the working directory is in hub {hub!r}, not {HUB!r}: run from ~/local/asyla")
    for n in ("OPENBAO_TOKEN", "OPENBAO_TOKEN_FILE"):   # the hub's own sign-in, never another token
        os.environ.pop(n, None)
    try:
        tok = oc.token()
    except oc.OpenBaoError as e:
        raise Stop(f"asyla's hub token: {e}")
    if not tok:
        raise Stop("asyla's hub token: empty")
    return tok


def take_given_token() -> str | None:
    """VAULT_TOKEN_ENV's value, taken out of this process's environment (so no child gets it under
    that name), or None when it is unset. Set but empty, or with a blank inside: Stop. Never
    printed."""
    raw = os.environ.pop(VAULT_TOKEN_ENV, None)
    if raw is None:
        return None
    tok = raw.strip()
    if not tok:
        raise Stop(f"{VAULT_TOKEN_ENV} is set but empty; nothing contacted")
    if any(c.isspace() or not c.isprintable() for c in tok):
        raise Stop(f"{VAULT_TOKEN_ENV} is not one token (a blank or a control character inside); nothing contacted")
    return tok


def show_plan(spec: dict, tag: str, registry: str, identities: list, given_token: bool = False) -> None:
    a = app_of(spec)
    pull = a.get("pull_token_env")
    script = build_host.app_script(spec['apps_tree'], APP)
    print(f"deploy {APP} on {spec['host']} (token role {VAULT_ROLE}), theOrg observability images "
          f"{registry}/theorg/*:{tag[:12]}")
    print(f"  pull token {pull}: {'set' if pull and os.environ.get(pull) else 'MISSING'} (names only)")
    print(f"1. {spec['host']}: {script} images (over SSH stdin: {build_host.pull_env_name(APP)}): pulls "
          f"every theOrg image (others when missing); theOrg images must be {registry}/...:{tag[:12]}")
    print(f"2. {spec['host']}: {script} digests (the same theOrg images); the registry's provenance of each "
          f"digest (by digest, hash-checked) must name exactly one theOrg commit R"
          f"{' (= ' + tag[:12] + ')' if tag != 'latest' else ''}, source on {origin('https://' + registry)[0]}")
    print(f"3. git fetch origin in {THEORG_CLONE}; R and TOOL_REV {TOOL_REV[:12]} on its origin/main; "
          f"scripts/{{{','.join(TOOL_FILES)}}} the same at R as at TOOL_REV; git show "
          f"TOOL_REV:scripts/{{{','.join(TOOL_FILES)}}} into a private temp dir (removed after)")
    who = (f"the vault token {VAULT_TOKEN_ENV} gave (set)" if given_token
           else "asyla's hub token (openbao_client.token(), cwd hub)")
    print(f"4. {who} as BAO_TOKEN in the minting tool's environment only; {', '.join(CALLER_TOKENS)} removed")
    print(f"5. vault_identity.py --token-role {VAULT_ROLE}:")
    for component, env, records in identities:
        print(f"     {component:18} -> {env}  kv: {', '.join(kv_path(r) for r in records)}")
    start = start_argv(spec)
    print(f"   then: {' '.join(['python3', str(Path(start[1]).relative_to(REPO))] + start[2:])}")
    print(f"   (observability.sh up gets {', '.join(e for _, e, _ in identities)} over SSH stdin)")
    print(f"6. {spec['host']}: OBSERVABILITY_REVISION=R {script} "
          f"{' '.join(app_of(spec).get('verify', []))} (no token); a failure exits 1")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="print the plan; mint nothing, contact nothing")
    mode.add_argument("--revision-only", action="store_true",
                      help="steps 1-3 (pull, digests, provenance, origin/main, TOOL_REV check), print R; "
                           "no hub token, mint nothing, start nothing")
    args = p.parse_args(argv)
    try:
        given = take_given_token()   # first: out of os.environ before any child (git, ssh) runs
        spec = build_host.load_spec(HOST)
        check_spec(spec, IDENTITIES)
        tag = stack_tag(HERE / f"{APP}.sh")
        registry = stack_registry(HERE / f"{APP}.sh")
        show_plan(spec, tag, registry, IDENTITIES, given is not None)
        if args.dry_run:
            print("DRY RUN: nothing minted, nothing contacted")
            return 0
        a = app_of(spec)
        build_host.from_env(a["pull_token_env"], f"[[app]] {APP} pull_token_env")   # unset: stop here
        if args.revision_only:
            print("REVISION ONLY: steps 1-3, then stop")
            build_host.step("images")
            pulled = pull_images(spec, tag, registry)
            build_host.step("revision")
            rev = stack_revision(spec, tag, registry, pulled)
            build_host.step("tool check")
            check_tool(rev)
            print(f"R = {rev} (theOrg observability, on origin/main; the minting tool there is the same as "
                  f"at TOOL_REV {TOOL_REV[:12]})")
            print("REVISION ONLY: nothing minted, nothing started")
            return 0
        tool_dir = Path(tempfile.mkdtemp(prefix="obs-mint-"))                     # 0700
        try:
            build_host.step("images")
            pulled = pull_images(spec, tag, registry)
            build_host.step("revision")
            rev = stack_revision(spec, tag, registry, pulled)
            build_host.step("tool")
            unpack_tool(rev, tool_dir)
            build_host.step("mint and start")
            env = child_env(os.environ, given if given is not None else hub_sign_in(), spec)
            try:
                rc, started = run_start(mint_argv(tool_dir, IDENTITIES, spec), env)
            except OSError as e:
                raise Stop(f"cannot run vault_identity.py: {type(e).__name__}; nothing minted, nothing started")
        finally:
            shutil.rmtree(tool_dir, ignore_errors=True)
        host, script = spec["host"], build_host.app_script(spec["apps_tree"], APP)
        if rc != 0 and not started:
            print(f"stopped: the mint failed (exit {rc}; vault_identity.py's ::error:: line is above): "
                  f"nothing started")
            return rc
        if rc != 0:
            print(f"stopped: the start failed (exit {rc}; its lines are above): the stack may be partly "
                  f"recreated. On {host}, run `{script} status` and `{script} verify`")
            return rc
        build_host.step("verify")
        verify_app(spec, rev)
        print(f"{APP} started on {host} with {len(IDENTITIES)} vault identities at theOrg observability "
              f"{rev}, and verifies")
        return 0
    except (Stop, build_host.Fail) as e:
        print(f"stopped: {e}")
        return 1
    except subprocess.CalledProcessError as e:   # git show (names only in its command)
        print(f"stopped: {' '.join(e.cmd)}: exit {e.returncode}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
