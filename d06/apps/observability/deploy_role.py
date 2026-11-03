#!/usr/bin/env python3
"""Deploy d06's observability stack with its components' vault identities (token-role mode).

Run on the workstation, from ~/local/asyla (asyla's hub token is the hub of the working directory):

    cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN -- \\
        python3 projects/asyla-hosts/d06/apps/observability/deploy_role.py [--dry-run]

1. images: `observability.sh images` on d06, with the registry pull token over SSH stdin
   (build_host.py's own helpers), before any mint: a wrapping token lives 300 s. The installed
   script must list theOrg images of the tag this repo's observability.sh pins.
2. the minting tool: theOrg observability's scripts/vault_identity.py and openbao.py at that same
   tag, `git show` from the local clone (THEORG_CLONE) into a private temp dir (0700, code only,
   removed after), so the clone's own checkout is never moved.
3. asyla's hub OpenBao token, in this process (secrets-vault's openbao_client.token(), the hub
   of the working directory), set only in the minting tool's environment as BAO_TOKEN;
   OPENBAO_TOKEN, VAULT_TOKEN and BAO_ROOT_TOKEN are removed from it.
4. `vault_identity.py --token-role observability-d06` with one --identity per IDENTITIES line,
   which then runs `build_host.py d06 build --only apps --app observability --apply`: build_host
   sends each wrapping token to `observability.sh up` over SSH stdin, as a start_env_optional
   name of d06/host.toml. A mint that fails (a missing record, a policy that does not take) exits
   1 before anything starts, and so does this script.

Never prints, logs or writes a token or a value; no file holds one. --dry-run prints the plan from
local files only: it mints nothing and contacts nothing (no SSH, no vault, no fetch).

Turning a component off, or adding a record to one, is a one-line edit of IDENTITIES.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
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
TAG_LINE = re.compile(r'^OBSERVABILITY_TAG="\$\{OBSERVABILITY_TAG_OVERRIDE:-([0-9a-f]{7,40})\}"', re.M)

# (component, the variable observability.sh up receives its wrapping token in, KV records under KV).
# Plain paths: vault_identity.py kv= takes no #field. One line per component.
IDENTITIES = [
    ("scrape-proxy", "SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN", ["home-assistant-prometheus-token"]),
    ("emporia-collector", "EMPORIA_OPENBAO_WRAPPED_TOKEN", ["emporia-username", "emporia-password"]),
    ("alert-relay", "ALERT_RELAY_OPENBAO_WRAPPED_TOKEN", ["smtp-relay-username", "smtp-relay-password"]),
]


class Stop(Exception):
    """A step failed: nothing after it runs."""


def stack_tag(script: Path) -> str:
    """The theOrg observability commit this repo's observability.sh pins (its OBSERVABILITY_TAG default)."""
    m = TAG_LINE.search(script.read_text())
    if not m:
        raise Stop(f"{script}: no OBSERVABILITY_TAG=\"${{OBSERVABILITY_TAG_OVERRIDE:-<sha>}}\" line")
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
    it), and no two identities share a component or an env=."""
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


def unpack_tool(tag: str, into: Path) -> None:
    """vault_identity.py and openbao.py at TAG into INTO (code only), fetching once if missing."""
    if not has_tool(tag):
        print(f"  {tag[:12]} not in {THEORG_CLONE}: fetching origin once")
        if git("fetch", "--quiet", "origin", check=False).returncode != 0 or not has_tool(tag):
            raise Stop(f"scripts/{' and '.join(TOOL_FILES)} at {tag[:12]} not in {THEORG_CLONE}")
    for f in TOOL_FILES:
        (into / f).write_text(git("show", f"{tag}:scripts/{f}").stdout)
    if "--token-role" not in (into / "vault_identity.py").read_text():
        raise Stop(f"vault_identity.py at {tag[:12]} has no --token-role mode")


def redact(text: str, values: list[str]) -> str:
    for v in values:
        if v:
            text = text.replace(v, "...")
    return text


def pull_images(spec: dict, tag: str) -> None:
    """`observability.sh images` on the host with the pull token over stdin; its theOrg images
    must be of TAG (the installed script is this repo's)."""
    a = app_of(spec)
    pairs = build_host.app_env(spec, a, start=False)
    cmd, stdin = build_host.env_command(pairs, f"{build_host.app_script(spec['apps_tree'], APP)} images")
    r = build_host.ssh(spec["host"], cmd, stdin=stdin, check=False, timeout=1800)
    if r.returncode != 0:
        tail = redact((r.stderr or "")[-2000:], [v for _, v in pairs])
        sys.stderr.write(tail + ("\n" if tail and not tail.endswith("\n") else ""))
        raise Stop(f"`{APP}.sh images` on {spec['host']}: exit {r.returncode}; nothing minted, nothing started")
    images = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    theorg = [i for i in images if "/theorg/" in i]
    stale = [i for i in theorg if not i.endswith(f":{tag}")]
    if not theorg or stale:
        raise Stop(f"{spec['host']}'s installed {APP}.sh lists {len(theorg)} theOrg image(s), "
                   f"{len(stale)} not of {tag[:12]}: its scripts tree is not this repo's; nothing minted")
    print(f"  {len(images)} image(s) present, {len(theorg)} theOrg image(s) of {tag[:12]}")


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
    print(f"deploy {APP} on {spec['host']} (token role {VAULT_ROLE}), theOrg observability {tag[:12]}")
    print(f"  pull token {pull}: {'set' if pull and os.environ.get(pull) else 'MISSING'} (names only)")
    print(f"1. {spec['host']}: {build_host.app_script(spec['apps_tree'], APP)} images "
          f"(over SSH stdin: {build_host.pull_env_name(APP)}); theOrg images must be :{tag[:12]}")
    print(f"2. git show {tag[:12]}:scripts/{{{','.join(TOOL_FILES)}}} from {THEORG_CLONE} into a private "
          f"temp dir (removed after); in the clone now: {'yes' if has_tool(tag) else 'no (fetched once)'}")
    print(f"3. asyla's hub token (openbao_client.token(), cwd hub) as BAO_TOKEN in the minting tool's "
          f"environment only; {', '.join(CALLER_TOKENS)} removed")
    print(f"4. vault_identity.py --token-role {VAULT_ROLE}:")
    for component, env, records in identities:
        print(f"     {component:18} -> {env}  kv: {', '.join(f'{KV}/{r}' for r in records)}")
    start = start_argv(spec)
    print(f"   then: {' '.join(['python3', str(Path(start[1]).relative_to(REPO))] + start[2:])}")
    print(f"   (observability.sh up gets {', '.join(e for _, e, _ in identities)} over SSH stdin)")


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
            build_host.step("tool")
            unpack_tool(tag, tool_dir)
            build_host.step("images")
            pull_images(spec, tag)
            build_host.step("mint and start")
            env = child_env(os.environ, hub_sign_in(), spec)
            r = subprocess.run(mint_argv(tool_dir, IDENTITIES, spec), env=env)
        finally:
            shutil.rmtree(tool_dir, ignore_errors=True)
        if r.returncode != 0:
            print(f"vault_identity.py or the start: exit {r.returncode} (a mint failure starts nothing; "
                  f"its message is above)")
            return r.returncode
        print(f"{APP} started on {spec['host']} with {len(IDENTITIES)} vault identities")
        return 0
    except (Stop, build_host.Fail) as e:
        print(f"stopped: {e}")
        return 1
    except subprocess.CalledProcessError as e:   # git show (names only in its command)
        print(f"stopped: {' '.join(e.cmd)}: exit {e.returncode}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
