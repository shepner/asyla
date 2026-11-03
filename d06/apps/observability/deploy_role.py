#!/usr/bin/env python3
"""Deploy d06's observability stack with its components' vault identities (token-role mode).

Run on the workstation, from ~/local/asyla (asyla's hub token is the hub of the working directory):

    cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN -- \\
        python3 projects/asyla-hosts/d06/apps/observability/deploy_role.py [--dry-run]

1. images: `observability.sh images` on d06, with the registry pull token over SSH stdin
   (build_host.py's own helpers), before any mint: a wrapping token lives 300 s. It pulls every
   image, so a newer `latest` replaces the one d06 has. The installed script must list theOrg
   images of the tag this repo's observability.sh names: `latest`, or a theOrg sha a commit pins.
2. revision: the theOrg observability commit the pulled images were built from. `observability.sh
   digests` on d06 (no token) gives the registry digest each theOrg image was pulled by; the
   provenance attestation the registry holds in that image index (buildkit's, from theOrg's
   publish-images) names its vcs.revision, with vcs.source theOrg's observability repo. Every
   theOrg image must name the same commit (a pinned sha: that one), else exit 1, nothing minted.
   Not the OCI revision label: theOrg's images do not set it, and loki's carries its base image's.
3. the minting tool: theOrg observability's scripts/vault_identity.py and openbao.py at that
   revision, `git show` from the local clone (THEORG_CLONE) into a private temp dir (0700, code
   only, removed after), so the clone's own checkout is never moved. The clone is fetched first,
   and the revision must be on its origin/main (`latest` is pushed from main only; this code mints
   with asyla's hub token).
4. asyla's hub OpenBao token, in this process (secrets-vault's openbao_client.token(), the hub
   of the working directory), set only in the minting tool's environment as BAO_TOKEN;
   OPENBAO_TOKEN, VAULT_TOKEN and BAO_ROOT_TOKEN are removed from it.
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

Turning a component off, or adding a record to one, is a one-line edit of IDENTITIES.
"""
from __future__ import annotations

import argparse
import base64
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
THEORG_CLONE = Path.home() / "local/theOrg/projects/observability"
SECRETS_CLIENT = Path.home() / "local/theOrg/projects/secrets-vault/client"   # data/components.toml openbao
TOOL_FILES = ("vault_identity.py", "openbao.py")
CALLER_TOKENS = ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_ROOT_TOKEN")
TAG_LINE = re.compile(r'^OBSERVABILITY_TAG="\$\{OBSERVABILITY_TAG_OVERRIDE:-([0-9a-f]{7,40}|latest)\}"', re.M)
IMAGES_TIMEOUT = 1800   # s: `images` pulls every image
DIGESTS_TIMEOUT = 120   # s: `digests` reads the local images only
REGISTRY_TIMEOUT = 30   # s: per registry request
REGISTRY_USER = "theorg-registry"   # the pull token's user, as docker-credential-observability-env answers
THEORG_SOURCE = "/theorg/observability"   # a provenance vcs.source's path (case-insensitive, no .git)
REVISION = re.compile(r"[0-9a-f]{40}")
INDEX_ACCEPT = ", ".join(("application/vnd.oci.image.index.v1+json",
                          "application/vnd.docker.distribution.manifest.list.v2+json",
                          "application/vnd.oci.image.manifest.v1+json"))
VERIFY_TIMEOUT = 1800   # s: verify waits up to VERIFY_WAIT_S (300 s) per wait, a few in a row

# (component, the variable observability.sh up receives its wrapping token in, KV records under KV).
# Plain paths: vault_identity.py kv= takes no #field. One line per component.
IDENTITIES = [
    ("scrape-proxy", "SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN", ["home-assistant-prometheus-token"]),
    ("emporia-collector", "EMPORIA_OPENBAO_WRAPPED_TOKEN", ["emporia-username", "emporia-password"]),
    # The Watchdog's ping URL (on: observability.sh ALERT_WATCHDOG_PING). No delivery ping URL: on
    # with the forge token (compose.yml). The forge token's record is not stored yet.
    ("alert-relay", "ALERT_RELAY_OPENBAO_WRAPPED_TOKEN",
     ["smtp-relay-username", "smtp-relay-password", "observability-watchdog-ping-url"]),
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


def identity_args(identities: list) -> list[str]:
    """One --identity per component: component=, env=, and a plain-path kv= per record."""
    out = []
    for component, env, records in identities:
        if not records:
            raise Stop(f"{component}: no KV record; take its line out of IDENTITIES to turn it off")
        out += ["--identity", ",".join([f"component={component}", f"env={env}"]
                                       + [f"kv={KV}/{r}" for r in records])]
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
    drop = set(CALLER_TOKENS) | set(app_of(spec).get("start_env_optional", [])) | {"BAO_TOKEN"}
    env = {k: v for k, v in base.items() if k not in drop}
    env["BAO_TOKEN"] = signed_in
    return env


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(THEORG_CLONE), *args], capture_output=True, text=True,
                          check=check)


def has_tool(tag: str) -> bool:
    return all(git("cat-file", "-e", f"{tag}:scripts/{f}", check=False).returncode == 0 for f in TOOL_FILES)


def unpack_tool(rev: str, into: Path) -> None:
    """vault_identity.py and openbao.py at REV into INTO (code only), after a fetch of origin. REV
    must be on the clone's origin/main: `latest` is pushed from main only, and this code mints with
    asyla's hub token, so no other branch's code runs here."""
    if git("fetch", "--quiet", "origin", check=False).returncode != 0:
        print(f"  WARNING: git fetch origin in {THEORG_CLONE} failed; using the clone as it is")
    if not has_tool(rev):
        raise Stop(f"scripts/{' and '.join(TOOL_FILES)} at {rev[:12]} not in {THEORG_CLONE}; nothing minted")
    if git("merge-base", "--is-ancestor", rev, "origin/main", check=False).returncode != 0:
        raise Stop(f"{rev[:12]} is not on origin/main of {THEORG_CLONE}; nothing minted")
    for f in TOOL_FILES:
        (into / f).write_text(git("show", f"{rev}:scripts/{f}").stdout)
    if "--token-role" not in (into / "vault_identity.py").read_text():
        raise Stop(f"vault_identity.py at {rev[:12]} has no --token-role mode")


def redact(text: str, values: list[str]) -> str:
    for v in values:
        if v:
            text = text.replace(v, "...")
    return text


def pull_images(spec: dict, tag: str) -> None:
    """`observability.sh images` on the host with the pull token over stdin (it pulls every image);
    its theOrg images must be of TAG (the installed script is this repo's)."""
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
    theorg = [i for i in images if "/theorg/" in i]
    stale = [i for i in theorg if not i.endswith(f":{tag}")]
    if not theorg or stale:
        raise Stop(f"{host}'s installed {APP}.sh lists {len(theorg)} theOrg image(s), {len(stale)} not of "
                   f"{tag[:12]}: {host}'s scripts tree is not this repo's master; nothing minted. Merge this "
                   f"change to master, then install master on {host}: {bootstrap_hint(host)}; then run this again")
    print(f"  {len(images)} image(s) pulled, {len(theorg)} theOrg image(s) of {tag[:12]}")


def image_name(ref: str) -> str:
    return ref.rsplit("/", 1)[-1]


def split_ref(ref: str) -> tuple[str, str]:
    """(registry host, repository) of an image reference HOST/REPO[:TAG]."""
    host, rest = ref.split("/", 1)
    return host, (rest.rsplit(":", 1)[0] if ":" in rest.rsplit("/", 1)[-1] else rest)


def image_digests(spec: dict) -> dict[str, list[str]]:
    """Each theOrg image of the stack with the registry digest(s) the host pulled it by
    (`observability.sh digests`, no token): {reference: [sha256:...]}, [] for none."""
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
    for ln in r.stdout.splitlines():
        f = ln.split()
        if len(f) >= 2 and "/theorg/" in f[0]:
            out[f[0]] = [d for d in f[1:] if d.startswith("sha256:")]
    if not out:
        raise Stop(f"`{APP}.sh digests` on {host} listed no theOrg image; nothing minted")
    return out


class AuthStaysRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect keeps the Authorization header only to https on the same host; to any other host
    it goes without it, and a redirect off https is refused. urllib's own handler copies every
    header to wherever the redirect points."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is None:
            return None
        to, was = urllib.parse.urlsplit(new.full_url), urllib.parse.urlsplit(req.full_url)
        if to.scheme != "https":
            raise Stop(f"{was.hostname}: a redirect off https ({to.scheme or 'no scheme'}); nothing minted")
        if to.hostname != was.hostname:
            new.remove_header("Authorization")
        return new


OPENER = urllib.request.build_opener(AuthStaysRedirect)


def http_get(url: str, headers: dict) -> tuple[int, dict, bytes]:
    """(status, lower-cased headers, body) of a GET; an HTTP error status is returned, not raised.
    Only https (a redirect too: AuthStaysRedirect)."""
    if urllib.parse.urlsplit(url).scheme != "https":
        raise Stop(f"{urllib.parse.urlsplit(url).hostname}: not https; nothing minted")
    try:
        with OPENER.open(urllib.request.Request(url, headers=headers), timeout=REGISTRY_TIMEOUT) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
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
                        or realm.hostname != urllib.parse.urlsplit(f"https://{self.host}").hostname):
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
        h = {"Authorization": f"Bearer {self.bearer(repo)}", "Accept": INDEX_ACCEPT}
        st, _, body = http_get(f"https://{self.host}/v2/{repo}/{kind}/{ref}", h)
        if st != 200:
            raise Stop(f"{self.host}/{repo} {kind} {ref[:19]}: HTTP {st}; nothing minted")
        return json.loads(body)


def provenance_vcs(predicate: dict) -> dict:
    """buildkit's vcs record in a SLSA provenance predicate (v1, or v0.2), or {}."""
    v1 = ((predicate.get("runDetails") or {}).get("metadata") or {}).get("buildkit_metadata") or {}
    v02 = (predicate.get("metadata") or {}).get("https://mobyproject.org/buildkit@v1#metadata") or {}
    vcs = v1.get("vcs") or v02.get("vcs") or {}
    return vcs if isinstance(vcs, dict) else {}


def revisions_of(reg: Registry, repo: str, digest: str) -> set[str]:
    """The theOrg commits the provenance attestations of image index DIGEST name: one per
    attestation, "" for one that names none of theOrg observability's. Empty: no attestation."""
    revs = set()
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
            ok = src.scheme == "https" and src.path.rstrip("/").removesuffix(".git") == THEORG_SOURCE
            revs.add(rev if ok and REVISION.fullmatch(rev) else "")
    return revs


def stack_revision(spec: dict, tag: str) -> str:
    """The one theOrg observability commit every pulled theOrg image was built from (docstring,
    step 2); a pinned TAG must be that commit."""
    digests = image_digests(spec)
    secret = build_host.from_env(app_of(spec)["pull_token_env"], f"[[app]] {APP} pull_token_env")
    regs, found, bad = {}, {}, []
    try:
        for ref, ds in sorted(digests.items()):
            if not ds:
                bad.append(f"{image_name(ref)}: no registry digest on {spec['host']}")
                continue
            host, repo = split_ref(ref)
            reg = regs.setdefault(host, Registry(host, secret))
            revs = set().union(*(revisions_of(reg, repo, d) for d in ds))
            if len(revs) == 1 and "" not in revs:
                found[ref] = revs.pop()
            elif not revs or revs == {""}:
                bad.append(f"{image_name(ref)}: no theOrg revision in its provenance")
            else:
                bad.append(f"{image_name(ref)}: revisions {', '.join(sorted(r[:12] or 'none' for r in revs))}")
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


def show_plan(spec: dict, tag: str, identities: list) -> None:
    a = app_of(spec)
    pull = a.get("pull_token_env")
    script = build_host.app_script(spec['apps_tree'], APP)
    print(f"deploy {APP} on {spec['host']} (token role {VAULT_ROLE}), theOrg observability images :{tag[:12]}")
    print(f"  pull token {pull}: {'set' if pull and os.environ.get(pull) else 'MISSING'} (names only)")
    print(f"1. {spec['host']}: {script} images (over SSH stdin: {build_host.pull_env_name(APP)}): pulls "
          f"every image; theOrg images must be :{tag[:12]}")
    print(f"2. {spec['host']}: {script} digests; the registry's provenance of each theOrg image (by that "
          f"digest) must name one theOrg commit R{' (= ' + tag[:12] + ')' if tag != 'latest' else ''}")
    print(f"3. git fetch origin in {THEORG_CLONE}; R on its origin/main; git show "
          f"R:scripts/{{{','.join(TOOL_FILES)}}} into a private temp dir (removed after)")
    print(f"4. asyla's hub token (openbao_client.token(), cwd hub) as BAO_TOKEN in the minting tool's "
          f"environment only; {', '.join(CALLER_TOKENS)} removed")
    print(f"5. vault_identity.py --token-role {VAULT_ROLE}:")
    for component, env, records in identities:
        print(f"     {component:18} -> {env}  kv: {', '.join(f'{KV}/{r}' for r in records)}")
    start = start_argv(spec)
    print(f"   then: {' '.join(['python3', str(Path(start[1]).relative_to(REPO))] + start[2:])}")
    print(f"   (observability.sh up gets {', '.join(e for _, e, _ in identities)} over SSH stdin)")
    print(f"6. {spec['host']}: OBSERVABILITY_REVISION=R {script} "
          f"{' '.join(app_of(spec).get('verify', []))} (no token); a failure exits 1")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--dry-run", action="store_true", help="print the plan; mint nothing, contact nothing")
    args = p.parse_args(argv)
    try:
        spec = build_host.load_spec(HOST)
        check_spec(spec, IDENTITIES)
        tag = stack_tag(HERE / f"{APP}.sh")
        show_plan(spec, tag, IDENTITIES)
        if args.dry_run:
            print("DRY RUN: nothing minted, nothing contacted")
            return 0
        a = app_of(spec)
        build_host.from_env(a["pull_token_env"], f"[[app]] {APP} pull_token_env")   # unset: stop here
        tool_dir = Path(tempfile.mkdtemp(prefix="obs-mint-"))                     # 0700
        try:
            build_host.step("images")
            pull_images(spec, tag)
            build_host.step("revision")
            rev = stack_revision(spec, tag)
            build_host.step("tool")
            unpack_tool(rev, tool_dir)
            build_host.step("mint and start")
            env = child_env(os.environ, hub_sign_in(), spec)
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
