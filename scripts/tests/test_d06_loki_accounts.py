#!/usr/bin/env python3
"""Offline test of d06/apps/observability/loki_accounts.py: the accounts it reads, the tool's
environment and command line, the record path against compose.yml and deploy_role.py, and what
main() runs. No vault and no network: subprocess.run, deploy_role.git and
deploy_role.hub_sign_in are replaced so that any contact fails the test, or answer from stand-ins.
The one exception is a local `git show` of openbao.py at TOOL_REV from the theOrg clone (no fetch),
loaded to check the calls verify makes on it.

    python3 scripts/tests/test_d06_loki_accounts.py

Exit 0 when every case passes.
"""
from __future__ import annotations

import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "d06/apps/observability"))
import deploy_role as dr  # noqa: E402
import loki_accounts as la  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the test reached out: {a[:1]}")


REAL_RUN, REAL_GIT = subprocess.run, dr.git   # for the one local `git show` of openbao.py
subprocess.run = _no_contact
dr.git = _no_contact
dr.hub_sign_in = _no_contact

HUB_STAND_IN = "stand-in-hub"
OTHER_STAND_IN = "stand-in-other"
DROPPED = ("OPENBAO_TOKEN", "VAULT_TOKEN", "BAO_TOKEN", "BAO_ROOT_TOKEN", "OPENBAO_TOKEN_FILE",
           "OBSERVABILITY_DEPLOY_VAULT_TOKEN", "LOKI_CLIENTS_REGISTRY", "LOKI_CLIENTS_KV_PREFIX",
           "LOKI_CLIENTS_ANY")


def check(name: str, good: bool, detail: str = "") -> bool:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    return good


class Done:
    def __init__(self, rc: int, out: str = "", err: str = ""):
        self.returncode, self.stdout, self.stderr = rc, out, err


def quiet(call):
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc = call()
    return rc, buf.getvalue()


def registry_cases() -> list[bool]:
    out = [check("accounts: loki-clients.toml lists the 13 accounts, alert-relay and both check accounts among them",
                 len(la.accounts()) == 13 and "alert-relay" in la.accounts()
                 and all(n in la.accounts() for n in la.CHECK_ACCOUNTS), repr(la.accounts()))]
    with tempfile.TemporaryDirectory() as d:
        empty = Path(d) / "empty.toml"
        empty.write_text("# none\n")
        bad = Path(d) / "bad.toml"
        bad.write_text("[clients\n")
        for name, path, needle in (("a registry with no clients stops", empty, "no clients"),
                                   ("a registry that is not TOML stops", bad, "TOMLDecodeError"),
                                   ("a missing registry stops", Path(d) / "none.toml", "FileNotFoundError")):
            try:
                la.accounts(path)
                out.append(check(f"accounts: {name}", False, "no Stop"))
            except dr.Stop as e:
                out.append(check(f"accounts: {name}", needle in str(e), str(e)))
    return out


def env_cases() -> list[bool]:
    base = {"PATH": "/usr/bin", "HOME": "/home/x", "OPENBAO_ADDR": "https://vault.example",
            **{k: OTHER_STAND_IN for k in DROPPED}}
    env = la.child_env(base, HUB_STAND_IN)
    return [
        check("env: no other vault token and no LOKI_CLIENTS_* setting of the caller's reaches the tool",
              all(k not in env for k in DROPPED if k not in ("BAO_ROOT_TOKEN", "LOKI_CLIENTS_KV_PREFIX"))
              and OTHER_STAND_IN not in env.values(), repr(sorted(env))),
        check("env: the hub token as BAO_ROOT_TOKEN, asyla's prefix as LOKI_CLIENTS_KV_PREFIX",
              env.get("BAO_ROOT_TOKEN") == HUB_STAND_IN
              and env.get("LOKI_CLIENTS_KV_PREFIX") == "secret/hubs/asyla/own/loki-clients"),
        check("env: the rest of the caller's environment is kept (OPENBAO_ADDR, PATH, HOME)",
              all(env.get(k) == base[k] for k in ("OPENBAO_ADDR", "PATH", "HOME"))),
        check("env: the caller's environment is not changed", base["BAO_ROOT_TOKEN"] == OTHER_STAND_IN),
    ]


def path_cases() -> list[bool]:
    compose = (dr.HERE / "compose.yml").read_text()
    kv = [ln.split(":", 1)[1].strip().strip('"') for ln in compose.splitlines()
          if ln.strip().startswith("ALERT_RELAY_LOKI_KV:")]
    record = "own/loki-clients/alert-relay"
    return [
        check("path: the record is KV_PREFIX/alert-relay = compose.yml ALERT_RELAY_LOKI_KV less #password",
              len(kv) == 1 and kv[0].endswith("#password")
              and f"{la.KV_PREFIX}/alert-relay" == kv[0].removesuffix("#password"), repr(kv)),
        check("path: ... = deploy_role.kv_path of alert-relay's IDENTITIES record",
              f"{la.KV_PREFIX}/alert-relay" == dr.kv_path(record)
              and record in {c: rs for c, _, rs in dr.IDENTITIES}["alert-relay"]),
    ]


# Each registry, the observability.sh variable that lists its accounts, and the scopes its
# gateway's mode admits (theOrg DEPLOY.md, "Route modes": remote-write and pushgateway push only).
ACCOUNTS_VARS = {"loki": ("LOKI_GATEWAY_ACCOUNTS", (["push"], ["query"])),
                 "prometheus-write": ("PROMETHEUS_WRITE_GATEWAY_ACCOUNTS", (["push"],)),
                 "pushgateway": ("PUSHGATEWAY_GATEWAY_ACCOUNTS", (["push"],))}


def gateway_accounts_cases() -> list[bool]:
    """Each observability.sh <GATEWAY>_ACCOUNTS is what its registry yields: name:scope per
    account, comma-joined, in name order (theOrg loki_clients.py gateway-accounts)."""
    import tomllib
    sh = (dr.HERE / "observability.sh").read_text()
    exported = {w for m in re.finditer(r"^export (?:[^\n]*\\\n)*[^\n]*", sh, re.M) for w in m.group(0).split()}
    out = [check("registries: loki, prometheus-write and pushgateway, each its own file and prefix",
                 list(la.REGISTRIES) == ["loki", "prometheus-write", "pushgateway"]
                 and len({p for p, _ in la.REGISTRIES.values()}) == 3
                 and len({k for _, k in la.REGISTRIES.values()}) == 3
                 and all(k == f"secret/hubs/asyla/own/{p.stem}" for p, k in la.REGISTRIES.values()),
                 repr(la.REGISTRIES))]
    for reg, (var, scopes) in ACCOUNTS_VARS.items():
        clients = tomllib.loads(la.REGISTRIES[reg][0].read_text())["clients"]
        want = ",".join(f"{n}:{clients[n]['scope'][0]}" for n in sorted(clients))
        lines = [ln for ln in sh.splitlines() if ln.startswith(f"{var}=")]
        got = lines[0].split("=", 1)[1].strip('"') if len(lines) == 1 else ""
        out += [
            check(f"gateway {reg}: every account has exactly one scope its mode admits ({scopes})",
                  all(c.get("scope") in scopes for c in clients.values()), repr(clients)),
            check(f"gateway {reg}: observability.sh {var} = {la.REGISTRIES[reg][0].name}'s name:scope, in name order",
                  got == want, f"{got!r} != {want!r}"),
            check(f"gateway {reg}: observability.sh exports {var}", var in exported),
        ]
    return out


def argv_cases() -> list[bool]:
    tool_dir = Path("/stand-in/tool")
    argv = la.tool_argv(tool_dir)
    verify = la.tool_argv(tool_dir, mode="verify")
    return [check("argv: python -I loki_clients.py provision --registry <loki-clients.toml>",
                  argv == [sys.executable, "-I", "/stand-in/tool/loki_clients.py", "provision",
                           "--registry", str(dr.HERE / "loki-clients.toml")], repr(argv)),
            check("argv: verify --url https://loki.asyla.org --ca-volume '' (no --cacert)",
                  verify == [sys.executable, "-I", "/stand-in/tool/loki_clients.py", "verify",
                             "--registry", str(dr.HERE / "loki-clients.toml"),
                             "--url", "https://loki.asyla.org", "--ca-volume", ""], repr(verify))]


def main_cases() -> list[bool]:
    out = []
    rc, text = quiet(lambda: la.main(["--dry-run"]))
    out.append(check("dry run: exit 0, every registry's plan (default all), nothing fetched or signed in "
                     "(any contact fails)",
                     rc == 0 and "secret/hubs/asyla/own/loki-clients/alert-relay" in text
                     and "secret/hubs/asyla/own/prometheus-write-clients/host-agent-ws02" in text
                     and "secret/hubs/asyla/own/pushgateway-clients/staff-stack" in text
                     and "DRY RUN" in text, text))
    rc, text = quiet(lambda: la.main(["--registry", "pushgateway", "--dry-run"]))
    out.append(check("dry run --registry pushgateway: that registry's plan alone",
                     rc == 0 and "secret/hubs/asyla/own/pushgateway-clients/deploy-all" in text
                     and "loki-clients/" not in text and "prometheus-write-clients/" not in text, text))
    rc, text = quiet(lambda: la.main(["verify", "--registry", "all", "--dry-run"]))
    out.append(check("verify --registry all: stops, exit 1 (verify takes one gateway; any contact fails)",
                     rc == 1 and "verify takes one gateway" in text, text))
    rc, text = quiet(lambda: la.main(["verify", "--registry", "pushgateway", "--dry-run"]))
    out.append(check("verify --registry pushgateway dry run: exit 0, the url, deploy-all's record, every "
                     "check with its method, path and status, curl with the account on stdin; nothing "
                     "fetched, signed in or curled (any contact fails)",
                     rc == 0 and "DRY RUN" in text and "https://pushgateway.asyla.org" in text
                     and "secret/hubs/asyla/own/pushgateway-clients/deploy-all" in text
                     and "curlimages/curl" in text and "stdin" in text and "no --cacert" in text
                     and "GET /ready, want 200" in text
                     and "PUT /metrics/job/asyla_verify, want 401" in text
                     and "PUT /metrics/job/asyla_verify, want 200 or 202" in text
                     and "DELETE /metrics/job/asyla_verify, want 202" in text
                     and "GET /metrics, want 404" in text and "loki_clients.py verify" not in text, text))
    rc, text = quiet(lambda: la.main(["verify", "--registry", "prometheus-write", "--dry-run"]))
    out.append(check("verify --registry prometheus-write dry run: exit 0, host-agent-ws02's record, 401 "
                     "refusals, 204 for both of the account's writes and 200 for /ready; no 502 accepted",
                     rc == 0 and "https://prometheus-write.asyla.org" in text
                     and "secret/hubs/asyla/own/prometheus-write-clients/host-agent-ws02" in text
                     and text.count("POST /api/v1/write, want 401") == 2
                     and text.count("POST /api/v1/write, want 204\n") == 2
                     and "one sample of asyla_remote_write_verify" in text
                     and "GET /ready, want 200\n" in text and "502" not in text and "not deployed" not in text,
                     text))
    rc, text = quiet(lambda: la.main(["verify", "--dry-run"]))
    out.append(check("verify dry run: exit 0, the plan (url, no --cacert, both check accounts, curl), "
                     "nothing fetched, signed in or curled (any contact fails)",
                     rc == 0 and "DRY RUN" in text and "https://loki.asyla.org" in text
                     and "--ca-volume ''" in text and "curlimages/curl" in text
                     and all(n in text for n in la.CHECK_ACCOUNTS), text))

    saved = (dr.git, dr.hub_sign_in, subprocess.run)
    git_calls, runs = [], []

    def stand_in_git(*args, check=True):
        git_calls.append(args)
        return Done(0, "# stand-in code\n")

    def stand_in_run(argv, env=None, **kw):
        runs.append((argv, env, sorted(p.name for p in Path(argv[2]).parent.iterdir())))
        return Done(0, f"alert-relay: created {HUB_STAND_IN}\n")

    try:
        dr.git, dr.hub_sign_in, subprocess.run = stand_in_git, lambda: HUB_STAND_IN, stand_in_run
        signs = []
        dr.hub_sign_in = lambda: signs.append(1) or HUB_STAND_IN
        rc, text = quiet(la.main)
        argv, env, files = runs[0] if runs else ([], {}, [])
        want = [(la.tool_argv(Path(argv[2]).parent, p)[1:], k) for p, k in la.REGISTRIES.values()] if runs else []
        out += [
            check("run: the tool runs once per registry, in order, each with its own toml and prefix, "
                  "after one sign-in",
                  [(a[1:], e.get("LOKI_CLIENTS_KV_PREFIX")) for a, e, _ in runs] == want and len(signs) == 1,
                  repr(runs)),
            check("run: loki_clients.py and openbao.py unpacked beside it",
                  files == ["loki_clients.py", "openbao.py"], repr(files)),
            check("run: the code is unpacked once for every registry",
                  sum(1 for c in git_calls if c[0] == "show") == 2, repr(git_calls)),
            check("run: the code is shown from TOOL_REV after a fetch, and TOOL_REV is checked on origin/main",
                  ("fetch", "--quiet", "origin") in git_calls
                  and ("merge-base", "--is-ancestor", dr.TOOL_REV, dr.MAIN) in git_calls
                  and ("show", f"{dr.TOOL_REV}:scripts/loki_clients.py") in git_calls, repr(git_calls)),
            check("run: the hub token is in the tool's environment only, as BAO_ROOT_TOKEN",
                  env.get("BAO_ROOT_TOKEN") == HUB_STAND_IN and HUB_STAND_IN not in " ".join(argv)),
            check("run: exit 0, the tool's line passed on with the token masked",
                  rc == 0 and "alert-relay: created" in text and HUB_STAND_IN not in text, text),
            check("run: the temp dir is gone after", bool(argv) and not Path(argv[2]).parent.exists()),
        ]

        runs.clear()
        subprocess.run = stand_in_run
        rc, text = quiet(lambda: la.main(["verify"]))
        argv, env, files = runs[0] if runs else ([], {}, [])
        out.append(check("verify: the tool runs once as verify, with the same prefix and the hub token, "
                         "and exit 0 says every check passed",
                         rc == 0 and len(runs) == 1 and argv[1:] == la.tool_argv(Path(argv[2]).parent, mode="verify")[1:]
                         and env.get("BAO_ROOT_TOKEN") == HUB_STAND_IN
                         and env.get("LOKI_CLIENTS_KV_PREFIX") == la.KV_PREFIX
                         and "every check passed" in text and HUB_STAND_IN not in text, text))

        runs.clear()
        subprocess.run = lambda argv, env=None, **kw: Done(1, "", "::error::stand-in refused\n")
        rc, text = quiet(la.main)
        out.append(check("run: a tool failure exits 1 with its line and a stopped: line naming the "
                         "registries not run",
                         rc == 1 and "::error::stand-in refused" in text and "stopped:" in text
                         and "not run: prometheus-write, pushgateway" in text, text))

        runs.clear()
        subprocess.run = stand_in_run
        rc, text = quiet(lambda: la.main(["--registry", "prometheus-write"]))
        argv, env, files = runs[0] if runs else ([], {}, [])
        out.append(check("run --registry prometheus-write: the tool runs once, with that toml and prefix",
                         rc == 0 and len(runs) == 1
                         and argv[-1] == str(dr.HERE / "prometheus-write-clients.toml")
                         and env.get("LOKI_CLIENTS_KV_PREFIX") == "secret/hubs/asyla/own/prometheus-write-clients"
                         and "prometheus-write accounts: 1 stored" in text, text))

        signed = []
        dr.hub_sign_in = lambda: signed.append(1) or HUB_STAND_IN
        subprocess.run = _no_contact
        dr.git = lambda *a, check=True: Done(1 if a[0] == "merge-base" else 0, "")
        rc, text = quiet(la.main)
        out.append(check("run: TOOL_REV not on origin/main stops before the sign-in and the tool",
                         rc == 1 and "not on origin/main" in text and not signed, text))
    finally:
        dr.git, dr.hub_sign_in, subprocess.run = saved
    return out


ACCOUNT_STAND_IN = "stand-in-account-" + "a" * 32


class BaoError(Exception):
    def __init__(self, category: str):
        super().__init__(f"stand-in: {category}")
        self.category = category


class StandInBao:
    """openbao.py's kv_read and OpenBaoError, answering from records (or raising one category)."""
    OpenBaoError = BaoError

    def __init__(self, records: dict | None = None, fail: str = ""):
        self.records, self.fail, self.reads = records or {}, fail, []

    def kv_read(self, record, *, token):
        self.reads.append((record, token))
        if self.fail:
            raise BaoError(self.fail)
        if record not in self.records:
            raise BaoError("absent")
        return self.records[record]


def gateway(answers: dict, calls: list, bodies: list | None = None):
    """A stand-in subprocess.run for curl containers: the status for (method, path, who), who from
    the config on stdin (None, "wrong" or "account"). With bodies, each call's bound body file as
    (host path, its mode, its bytes, the --data-binary argument), or None with no -v."""
    def run(argv, input=None, env=None, **kw):
        if argv[:2] != ["docker", "run"]:
            raise AssertionError(f"not a curl container: {argv[:2]}")
        method = argv[argv.index("-X") + 1]
        path = "/" + argv[-1].split("/", 3)[3]
        who = None
        if input:
            who = "account" if input.endswith(f':{ACCOUNT_STAND_IN}"\n') else "wrong"
        if bodies is not None:
            data = argv[argv.index("--data-binary") + 1] if "--data-binary" in argv else None
            if "-v" in argv:
                host, inside, ro = argv[argv.index("-v") + 1].split(":")
                bodies.append((host, oct(os.stat(host).st_mode & 0o777), Path(host).read_bytes(), inside, ro, data))
            else:
                bodies.append(None)
        calls.append((argv, input, env, method, path, who))
        return Done(0, str(answers.get((method, path, who), 0)).zfill(3))
    return run


def ran(text: str) -> str:
    """The output after the plan (the check lines and the summary)."""
    return text.split("\ntoken:", 1)[-1].split("\n", 1)[-1]


PUSH_ANSWERS = {("GET", "/ready", None): 200, ("PUT", la.PUSH_JOB, None): 401,
                ("PUT", la.PUSH_JOB, "wrong"): 401, ("PUT", la.PUSH_JOB, "account"): 200,
                ("DELETE", la.PUSH_JOB, "account"): 202, ("GET", "/metrics", "account"): 404}
WRITE_ANSWERS = {("POST", "/api/v1/write", None): 401, ("POST", "/api/v1/write", "wrong"): 401,
                 ("POST", "/api/v1/write", "account"): 204, ("GET", "/ready", None): 200}


def snappy_decode(data: bytes) -> bytes:
    """A literal-only snappy block decoder (google/snappy format_description.txt), for the test:
    the varint length, then literal elements; any other element fails."""
    n = shift = i = 0
    while True:
        b = data[i]
        i += 1
        n |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            break
    out = bytearray()
    while i < len(data):
        tag = data[i]
        assert tag & 3 == 0 and tag >> 2 < 60, f"not a short literal tag: {tag:#x}"
        size = (tag >> 2) + 1
        out += data[i + 1:i + 1 + size]
        i += 1 + size
    assert len(out) == n, (len(out), n)
    return bytes(out)


def encoder_cases() -> list[bool]:
    """The remote-write encoders against bytes derived by hand from the formats (protobuf
    encoding; prometheus prompb remote.proto and types.proto; google/snappy
    format_description.txt). python-snappy is not installed here, so no library cross-check; the
    bodies were also sent to a throwaway prom/prometheus:v2.55.1 with the receiver on (204 each,
    and the sample read back by /api/v1/query), 2026-11-23."""
    import struct
    import time
    one = la.write_request({"job": "b", "__name__": "a"}, 1.0, 1000)
    want = bytes.fromhex(
        "0a27"                                     # WriteRequest.timeseries (1), 39 bytes
        "0a0d" "0a08" + b"__name__".hex() + "120161"   # TimeSeries.labels (1): name __name__, value a
        + "0a08" "0a03" + b"job".hex() + "120162"      # labels: name job, value b (name order)
        + "120c" "09" "000000000000f03f" "10e807")     # samples (2): value 1.0 (fixed64), timestamp 1000
    sample = la.verify_sample()
    now = time.time_ns() // 1_000_000
    raw = snappy_decode(sample)
    value = b"\x09" + struct.pack("<d", 1.0) + b"\x10"   # Sample.value 1.0, then the timestamp's tag
    ts = raw[raw.rindex(value) + len(value):] if value in raw else b""
    got_ts = sum((b & 0x7F) << (7 * k) for k, b in enumerate(ts))
    return [
        check("encode: varint 0, 1, 127, 128, 300 and a ms timestamp",
              [la.varint(n).hex() for n in (0, 1, 127, 128, 300, 1795439103158)]
              == ["00", "01", "7f", "8001", "ac02", "b6998ac4a034"]),
        check("encode: a length-delimited field is its tag, its length, the payload",
              la.pb_bytes(1, b"abc") == b"\x0a\x03abc" and la.pb_bytes(2, b"") == b"\x12\x00"),
        check("encode: write_request of {__name__=a, job=b} 1.0 at 1000 is the hand-derived bytes",
              one == want, one.hex()),
        check("snappy: the empty input is the single byte 0x00, and that is EMPTY_WRITE",
              la.snappy_literal(b"") == b"\x00" == la.EMPTY_WRITE),
        check("snappy: 3 bytes are varint 3, tag (3-1)<<2, the bytes",
              la.snappy_literal(b"abc") == bytes.fromhex("0308616263")),
        check("snappy: 61 bytes are varint 61, a 60-byte literal (tag 0xec), a 1-byte one (tag 0x00)",
              la.snappy_literal(bytes(range(61))) == b"\x3d\xec" + bytes(range(60)) + b"\x00\x3c"),
        check("snappy: 300 bytes start with varint 300 (ac 02) and are 5 literals of 60, each tagged 0xec",
              (s := la.snappy_literal(bytes(300)))[:2] == b"\xac\x02" and len(s) == 2 + 5 * 61
              and all(s[2 + k * 61] == 0xEC for k in range(5))),
        check("verify_sample: decodes to one TimeSeries of asyla_remote_write_verify{job=asyla-verify} 1 "
              "at about now",
              raw == la.write_request(la.VERIFY_SERIES, 1.0, got_ts) and abs(got_ts - now) < 5000
              and len(sample) > 61 and la.VERIFY_SERIES == {"__name__": "asyla_remote_write_verify", "job": "asyla-verify"},
              raw.hex()),
    ]


def metrics_cases() -> list[bool]:
    out = []
    argv = la.curl_argv("https://pushgateway.asyla.org/metrics/job/asyla_verify", "PUT", la.PUSH_BODY,
                        la.TEXT_FORMAT)
    out.append(check("curl argv: the image pinned by digest, config from stdin (-K -), no --cacert, "
                     "never -k/--insecure, no account",
                     argv[:3] == ["docker", "run", "--rm"] and la.CURL_IMAGE in argv
                     and re.fullmatch(r"curlimages/curl:[0-9.]+@sha256:[0-9a-f]{64}", la.CURL_IMAGE)
                     and argv[argv.index("-K") + 1] == "-" and "--cacert" not in argv
                     and "-k" not in argv and "--insecure" not in argv and "-u" not in argv
                     and "--user" not in argv and argv[-1].endswith(la.PUSH_JOB)
                     and argv[argv.index("--data-binary") + 1] == "asyla_verify_push 1\n", repr(argv)))
    w = la.curl_argv("https://prometheus-write.asyla.org/api/v1/write", "POST", None, la.REMOTE_WRITE,
                     "/stand-in/body")
    out.append(check("curl argv: a remote write binds its body file read-only as /body before the image, "
                     "sends @/body, with the remote-write headers; stdin stays the config",
                     w[w.index("--data-binary") + 1] == "@/body"
                     and w[w.index("-v") + 1] == f"{os.path.realpath('/stand-in/body')}:/body:ro"
                     and w.index("-v") < w.index(la.CURL_IMAGE) and w[w.index("-K") + 1] == "-"
                     and all(h in w for h in ("Content-Type: application/x-protobuf", "Content-Encoding: snappy",
                                              "X-Prometheus-Remote-Write-Version: 0.1.0")), repr(w)))
    p = la.curl_argv("https://pushgateway.asyla.org" + la.PUSH_JOB, "PUT", la.PUSH_BODY, la.TEXT_FORMAT)
    out.append(check("curl argv: a text body binds nothing", "-v" not in p, repr(p)))

    # read_password(): the record at the registry's prefix, read with the hub token; Stop never shows it.
    rec = "secret/hubs/asyla/own/pushgateway-clients/deploy-all"
    bao = StandInBao({rec: {"username": "deploy-all", "password": ACCOUNT_STAND_IN}})
    got = la.read_password(bao, HUB_STAND_IN, "pushgateway")
    out.append(check("read_password() reads deploy-all's record under pushgateway-clients, with the hub token",
                     got == ACCOUNT_STAND_IN and bao.reads == [(rec, HUB_STAND_IN)], repr(bao.reads)))
    short = ACCOUNT_STAND_IN[:20]
    for name, b, needle in (
            ("no record stops, naming provision", StandInBao(), "absent; run loki_accounts.py --registry pushgateway"),
            ("a refused read stops", StandInBao(fail="refused"), "refused"),
            ("another username stops", StandInBao({rec: {"username": "other", "password": ACCOUNT_STAND_IN}}),
             "username is not deploy-all"),
            ("a short value stops, not shown", StandInBao({rec: {"username": "deploy-all", "password": short}}),
             "not a secrets.token_urlsafe(32) value"),
            ("a quote in the value stops", StandInBao({rec: {"username": "deploy-all",
                                                              "password": ACCOUNT_STAND_IN + '"'}}),
             "not a secrets.token_urlsafe(32) value")):
        try:
            la.read_password(b, HUB_STAND_IN, "pushgateway")
            out.append(check(f"read_password() - {name}", False, "no Stop"))
        except dr.Stop as e:
            out.append(check(f"read_password() - {name}", needle in str(e) and short not in str(e), str(e)))

    saved = (dr.git, dr.hub_sign_in, subprocess.run, la.load_openbao)
    records = {rec: {"username": "deploy-all", "password": ACCOUNT_STAND_IN},
               "secret/hubs/asyla/own/prometheus-write-clients/host-agent-ws02":
                   {"username": "host-agent-ws02", "password": ACCOUNT_STAND_IN}}
    dirs = []

    def stand_in_load(tool_dir):
        dirs.append(tool_dir)
        return StandInBao(records)

    try:
        dr.git = lambda *a, check=True: Done(0, "# stand-in code\n")
        dr.hub_sign_in = lambda: HUB_STAND_IN
        la.load_openbao = stand_in_load
        calls = []
        subprocess.run = gateway(PUSH_ANSWERS, calls)
        caller = {k: os.environ.get(k) for k in DROPPED}
        os.environ.update({k: OTHER_STAND_IN for k in DROPPED})
        try:
            rc, text = quiet(lambda: la.main(["verify", "--registry", "pushgateway"]))
        finally:
            for k, v in caller.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        seen = [(m, p, who) for _, _, _, m, p, who in calls]
        out += [
            check("verify pushgateway: exit 0, six ok lines, every check passed",
                  rc == 0 and text.count("\nok ") + text.startswith("ok ") == 6 and "FAIL" not in text
                  and "pushgateway gateway: every check passed at https://pushgateway.asyla.org" in text, text),
            check("verify pushgateway: the checks in order (ready, anonymous, wrong, push, delete, /metrics)",
                  seen == [("GET", "/ready", None), ("PUT", la.PUSH_JOB, None), ("PUT", la.PUSH_JOB, "wrong"),
                           ("PUT", la.PUSH_JOB, "account"), ("DELETE", la.PUSH_JOB, "account"),
                           ("GET", "/metrics", "account")], repr(seen)),
            check("verify pushgateway: the password only in curl's stdin config, never on argv or in "
                  "the environment, and never printed; the token neither",
                  all(ACCOUNT_STAND_IN not in " ".join(a) and HUB_STAND_IN not in " ".join(a)
                      and isinstance(e, dict) and ACCOUNT_STAND_IN not in e.values()
                      and HUB_STAND_IN not in e.values() for a, _, e, *_ in calls)
                  and all(i == "" if who is None else i.startswith('user = "deploy-all:')
                          for _, i, _, _, _, who in calls)
                  and ACCOUNT_STAND_IN not in text and HUB_STAND_IN not in text, text),
            check("verify pushgateway: no caller vault token or LOKI_CLIENTS_* setting reaches docker",
                  bool(calls) and all(not any(k in e for k in DROPPED) and OTHER_STAND_IN not in e.values()
                                      and "PATH" in e for _, _, e, *_ in calls),
                  repr(sorted(calls[0][2]) if calls else [])),
            check("verify pushgateway: the wrong password is not derived from the account's",
                  [len(i) for _, i, _, _, _, who in calls if who == "wrong"] == [len('user = "deploy-all:"\n') + 43]
                  and all(ACCOUNT_STAND_IN[17:] not in i for _, i, _, _, _, who in calls if who == "wrong"),
                  repr([who for *_, who in calls])),
            check("verify pushgateway: the openbao.py temp dir is gone after",
                  len(dirs) == 1 and not dirs[0].exists(), repr(dirs)),
        ]

        calls.clear()
        subprocess.run = gateway({**PUSH_ANSWERS, ("PUT", la.PUSH_JOB, None): 200}, calls)
        rc, text = quiet(lambda: la.main(["verify", "--registry", "pushgateway"]))
        out.append(check("verify pushgateway: an anonymous push let through is a FAIL line and exit 1; "
                         "the rest still run (the delete cleans up)",
                         rc == 1 and "FAIL push, no account" in text and "stopped:" in text
                         and len(calls) == 6, text))

        calls.clear()
        answer = gateway(PUSH_ANSWERS, calls)

        def broken_push(argv, input=None, env=None, **kw):
            if argv[argv.index("-X") + 1] == "PUT" and input and input.endswith(f':{ACCOUNT_STAND_IN}"\n'):
                raise RuntimeError("stand-in failure")
            return answer(argv, input=input, env=env, **kw)

        subprocess.run = broken_push
        try:
            quiet(lambda: la.main(["verify", "--registry", "pushgateway"]))
            raised = False
        except RuntimeError:
            raised = True
        out.append(check("verify pushgateway: the DELETE cleanup still runs when a check raises",
                         raised and [(m, p) for _, _, _, m, p, _ in calls][-1] == ("DELETE", la.PUSH_JOB),
                         repr([(m, p, w) for _, _, _, m, p, w in calls])))

        calls.clear()
        subprocess.run = gateway({**PUSH_ANSWERS, ("PUT", la.PUSH_JOB, "account"): 202}, calls)
        rc, _ = quiet(lambda: la.main(["verify", "--registry", "pushgateway"]))
        out.append(check("verify pushgateway: a push answered 202 passes too", rc == 0))

        calls.clear()
        bodies: list = []
        subprocess.run = gateway(WRITE_ANSWERS, calls, bodies)
        rc, text = quiet(lambda: la.main(["verify", "--registry", "prometheus-write"]))
        seen = [(m, p, who) for _, _, _, m, p, who in calls]
        sent = [b[2] if b else None for b in bodies]
        out += [
            check("verify prometheus-write: exit 0, five ok lines; host-agent-ws02 signs in; the checks in "
                  "order (anonymous, wrong, empty WriteRequest, one sample, /ready)",
                  rc == 0 and ran(text).count("ok ") == 5 and "FAIL" not in text
                  and "every check passed at https://prometheus-write.asyla.org" in text
                  and seen == [("POST", "/api/v1/write", None), ("POST", "/api/v1/write", "wrong"),
                               ("POST", "/api/v1/write", "account"), ("POST", "/api/v1/write", "account"),
                               ("GET", "/ready", None)]
                  and all(i.startswith('user = "host-agent-ws02:') for _, i, _, _, _, w in calls if w)
                  and all("Content-Encoding: snappy" in a for a, *_ in calls[:4])
                  and ACCOUNT_STAND_IN not in text, text),
            check("verify prometheus-write: every write sends a valid snappy body from a 0600 file bound "
                  "read-only as /body: 0x00 three times, then the encoded sample; /ready none",
                  sent[:3] == [b"\x00"] * 3 and bodies[4] is None
                  and snappy_decode(sent[3]).startswith(b"\x0a") and b"asyla_remote_write_verify" in sent[3]
                  and all(b[1] == "0o600" and b[3:] == ("/body", "ro", "@/body") for b in bodies[:4]),
                  repr(bodies)),
            check("verify prometheus-write: each body file is gone after, and none holds the password",
                  all(not Path(b[0]).exists() and ACCOUNT_STAND_IN.encode() not in b[2] for b in bodies[:4]),
                  repr([b[0] for b in bodies[:4]])),
        ]

        for key, code, line in ((("POST", "/api/v1/write", "account"), 502, "FAIL write, host-agent-ws02, an empty"),
                                (("POST", "/api/v1/write", "account"), 400, "FAIL write, host-agent-ws02, an empty"),
                                (("GET", "/ready", None), 502, "FAIL /ready, no account")):
            calls.clear()
            subprocess.run = gateway({**WRITE_ANSWERS, key: code}, calls)
            rc, text = quiet(lambda: la.main(["verify", "--registry", "prometheus-write"]))
            out.append(check(f"verify prometheus-write: {key[0]} {key[1]} {code} is a FAIL, exit 1",
                             rc == 1 and line in text, text))

        calls.clear()
        subprocess.run = gateway({**WRITE_ANSWERS, ("POST", "/api/v1/write", "wrong"): 502}, calls)
        rc, text = quiet(lambda: la.main(["verify", "--registry", "prometheus-write"]))
        out.append(check("verify prometheus-write: a wrong password let through to the upstream is a FAIL",
                         rc == 1 and "FAIL write, wrong password" in text, text))

        calls.clear()
        subprocess.run = gateway(PUSH_ANSWERS, calls)
        records.clear()
        rc, text = quiet(lambda: la.main(["verify", "--registry", "pushgateway"]))
        out.append(check("verify pushgateway: no record stops before any curl, exit 1",
                         rc == 1 and "stopped:" in text and "absent" in text and not calls, text))
    finally:
        dr.git, dr.hub_sign_in, subprocess.run, la.load_openbao = saved
    return out


def real_openbao_cases() -> list[bool]:
    """openbao.py at TOOL_REV, shown from the local theOrg clone (no fetch) and loaded as
    loki_accounts.py loads it: the kv_read and OpenBaoError.category verify relies on."""
    import inspect
    saved = (dr.git, subprocess.run)
    try:
        dr.git, subprocess.run = REAL_GIT, REAL_RUN
        shown = dr.git("show", f"{dr.TOOL_REV}:scripts/openbao.py", check=False)
    finally:
        dr.git, subprocess.run = saved
    if shown.returncode != 0:
        return [check(f"real openbao.py: TOOL_REV {dr.TOOL_REV[:12]} not in {dr.THEORG_CLONE}", False)]
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "openbao.py").write_text(shown.stdout)
        bao = la.load_openbao(Path(d))
    params = list(inspect.signature(bao.kv_read).parameters.values()) if hasattr(bao, "kv_read") else []
    kinds = [(p.name, p.kind) for p in params[:2]]
    return [
        check("real openbao.py: kv_read(path, *, token, ...)",
              kinds == [("path", inspect.Parameter.POSITIONAL_OR_KEYWORD),
                        ("token", inspect.Parameter.KEYWORD_ONLY)], repr(params)),
        check("real openbao.py: OpenBaoError.category is a property; ABSENT reads 'absent'",
              isinstance(getattr(bao.OpenBaoError, "category", None), property)
              and bao.OpenBaoError("stand-in", bao.ABSENT).category == "absent"),
    ]


results = [*registry_cases(), *env_cases(), *path_cases(), *gateway_accounts_cases(), *argv_cases(),
           *main_cases(), *encoder_cases(), *metrics_cases(), *real_openbao_cases()]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
