# observability (d06)

theOrg's observability stack: Loki, Prometheus, the trends and ingest Prometheus, Alertmanager,
alert-relay, emporia-collector, scrape-proxy, the pushgateway, Vector, docker-state-exporter,
blackbox-exporter and three gateways from theOrg's loki-gateway image (theOrg's option B and route
modes, asyla #1268; On, off, below): loki-gateway, prometheus-write-gateway (in front of the ingest
Prometheus, which the operations Prometheus federates) and pushgateway-gateway. asyla deploys it here from
theOrg observability `DEPLOY.md`, last read at main `f7579118fdac5d90101a5ec6698200ae2c9d836f`
(#327; design 4 since #311). The images follow theOrg's `latest` (operator 2026-11-03: "keep
'latest' no matter what. Anything running older images will need to update"); the revision is read
from the images' provenance at deploy: `deploy_role.py` pulls every image on d06, reads the theOrg
commit each was built from out of the provenance attestation the registry holds for the digest d06
pulled, and stops, with nothing minted or started, when one is missing, names no theOrg commit, or
the images disagree. It prints that revision and passes it to `verify`.

- `compose.yml`: theOrg's `docker-compose.yml` with `compose.docker-socket.yml` and
  `compose.blackbox.yml` folded in (the Docker-socket and blackbox pieces are on). `MONITOR_THEORG`
  is on ("theOrg's rules" below), with `THEORG_SCRAPE=false`, so theOrg's `scrape-theorg/`
  jobs are not here (communications' `chat-api` is); credential-probe and the Ollama log are theOrg's, not here. Project,
  container, volume and network names are theOrg's. No build sections.
- `observability.sh`: `up`, `down`, `restart`, `verify`, `update`, `pull`, `images`, `logs`,
  `status`, `digests`, `alert-test`. It names the tag (`latest`), sets the settings, creates the
  data directories and keeps the start order. A replica (a host with `[replica] of = "d06"`) runs
  only the services with nothing to reach off the host: no alert-relay, emporia-collector,
  scrape-proxy, Vector or any of the three gateways.
- `deploy_role.py`: the deploy (below): pulls, mints the six wrapped tokens, starts the stack.
- `loki_accounts.py` and the three account registries, created once in OpenBao (Secrets, below):
  `loki-clients.toml`, asyla's own 13 Loki accounts for d06, which loki-gateway checks
  (alert-relay's query account, the Mini's senders and readers, and the two check accounts),
  checked end to end; `prometheus-write-clients.toml` (1 account) for prometheus-write-gateway;
  `pushgateway-clients.toml` (5 accounts) for pushgateway-gateway.
- Tests, offline: `python3 scripts/tests/test_d06_deploy_role.py`,
  `python3 scripts/tests/test_d06_loki_accounts.py` and `python3 scripts/tests/test_build_host_args.py`.
- `prometheus/rules/`, `prometheus/scrape/`: asyla's own alert rules and scrape jobs, mounted
  read-only over the operations Prometheus's `/etc/prometheus/rules` and `/etc/prometheus/scrape`;
  `prometheus/tests/`: their promtool tests ([Hardware alerts](#hardware-alerts-asyla-610)).
- `docker-credential-observability-env`: the credential helper `observability.sh` points Docker at
  for the pulls (below).
- Data: `/mnt/docker/Observability/{alertmanager-data,loki-data,prometheus-data,prometheus-trends-data}`
  on d06's local data disk, bound into the named volumes; never NFS (theOrg decision
  asyla-network-monitoring section 8). Vector's disk buffer is a plain named volume.
- Caps: DEPLOY.md's defaults, none overridden here. Loki keeps 744h, ingests 0.05 MB/s with a
  burst of 16 MB; Prometheus keeps 15d or 8GB; the trends Prometheus keeps 24GB (size only, sized
  for the 64 GiB data disk). `compose.yml` takes `PROMETHEUS_RETENTION_TIME`,
  `PROMETHEUS_RETENTION_SIZE` and `TRENDS_RETENTION_SIZE` from the environment if one is ever set.
- Ports: none on every address; each published port is on `127.0.0.1` only: Prometheus `9090`,
  trends `9107` (container `9090`), Alertmanager `9093`, alert-relay `9111`, Vector `9598`,
  docker-state-exporter `9099`. Loki (`3100`, plain HTTP, reached in the stack as `loki:3100`),
  the three gateways (each `3100`, plain HTTP, reached by Caddy by its edge alias on `loki-edge`),
  the pushgateway (`9091`, reached only on `push`), prometheus-ingest (`9090`, reached only on
  `ingest`), alert-relay's health port, emporia-collector (`9108`), scrape-proxy (`9119`) and
  blackbox-exporter are not published. The pushgateway's old `127.0.0.1:9091` publish is dropped:
  a grep of asyla-hosts for `9091` found no d06 user of it (the other hits are d01's own apps and
  communications' list of ports d06 had in use). The operations Prometheus's own remote-write receiver stays off; remote writes go to
  prometheus-ingest (Gateways, below).
- Names (`caddy-internal-d06`, LAN only): `prometheus.asyla.org`, `alertmanager.asyla.org`,
  `prometheus-trends.asyla.org`, `loki.asyla.org`, `prometheus-write.asyla.org` and
  `pushgateway.asyla.org`. The first three are the external URLs Prometheus and Alertmanager put
  in links (`PROMETHEUS_EXTERNAL_URL`, `ALERTMANAGER_EXTERNAL_URL` in `observability.sh`). For
  the three gateway names, d06's Caddy ends TLS with a Let's Encrypt certificate, as it does for
  `nats.asyla.org`, and reaches the gateway in plain HTTP by its edge alias:
  `loki-gateway-edge:3100`, `prometheus-write-gateway-edge:3100` and
  `pushgateway-gateway-edge:3100`. That hop carries each caller's Basic-auth password in plain
  text, so it is not on `observability-net`, which the whole stack, `caddy-internal-d06` and
  communications' Vector share (a container there with `NET_RAW` could ARP-spoof it). It is on
  `loki-edge` (`observability-loki-edge`, `internal`, no egress), which only the three gateways
  and `caddy-internal-d06` join; the name is historical (it was loki-gateway's alone) and the
  network now carries all three gateways' hops. Each edge alias is on that network alone, so it
  resolves to its gateway's `loki-edge` address. `prometheus.asyla.org` refuses the write paths
  (`/api/v1/write`, `/api/v1/otlp`), so the operations Prometheus takes no write through Caddy.
  The proxy entries belong to the asyla `internal-access` repo (`hosts/d06/Caddyfile`).
- Networks: beside `observability-net`, three external networks, each `internal` (no egress):
  `observability-loki-edge` (`loki-edge`, above); `observability-ingest` (`ingest`), where
  prometheus-ingest's receiver takes writes, joined only by prometheus-write-gateway, the
  operations Prometheus and prometheus-ingest; `observability-push` (`push`), where anything on it
  can push to or wipe the pushgateway, joined only by pushgateway-gateway, the operations
  Prometheus (which scrapes the pushgateway there) and the pushgateway, which is no longer on
  `observability-net`. Being external, compose never makes or removes them: `observability.sh`
  makes all three before every `up` (`ensure_networks`), with or without any gateway's token and
  on a replica too (compose needs every external network a started service joins: the operations
  Prometheus joins `ingest` and `push`), and refuses one that exists and is not internal (compose
  would use it as it is). internal-access makes `observability-loki-edge` the same way from
  `hosts/d06/networks.txt` (`observability-loki-edge internal`). Either stack may start first, and
  `down` leaves the networks, so the proxy's `up` never fails with "declared as external, but
  could not be found".

## Secrets

No secret is in any file, volume or container environment, here or on the host (core
`secrets.md` SEC-5 and SEC-7; the operator, 2026-11-03: "secrets are to live in the vault").
Nothing in this directory writes a value anywhere. Values reach `observability.sh` only as named
environment variables that the workstation sends at use over SSH stdin (build_host.py):

- `OBSERVABILITY_REGISTRY_PULL_TOKEN` (`pull_token_env = "THEORG_REGISTRY_PULL_TOKEN"` in
  `d06/host.toml`): the `theorg-registry` read:package token for the image pulls. The credential
  helper answers Docker from it under a throwaway `DOCKER_CONFIG`; nothing is stored.
- `ALERT_RELAY_OPENBAO_WRAPPED_TOKEN`, `EMPORIA_OPENBAO_WRAPPED_TOKEN`,
  `SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN`, `LOKI_GATEWAY_OPENBAO_WRAPPED_TOKEN`,
  `PROMETHEUS_WRITE_GATEWAY_OPENBAO_WRAPPED_TOKEN`, `PUSHGATEWAY_GATEWAY_OPENBAO_WRAPPED_TOKEN`
  (`start_env_optional` in `d06/host.toml`): each a
  response-wrapped, single-use token that `deploy_role.py` mints from the `observability-d06` token
  role (theOrg `scripts/vault_identity.py` at the images' revision). The component unwraps it once
  at start and holds the real token in memory, so what Docker keeps in the container's config is a
  spent wrapping token. A wrapping token lapses 300 s after it is minted.

Each component reads only the records its role policy grants (secrets-vault
`policies/hubs.toml`, `[token_roles.observability-d06.components]`), named in `compose.yml`, all
under `secret/hubs/asyla/` but alert-relay's Vikunja token:

- alert-relay (`ALERT_RELAY_<X>_KV`, `PATH#FIELD`): `smtp-relay-username#value`,
  `smtp-relay-password#value`, `observability-watchdog-ping-url#value`,
  `observability-delivery-ping-url#value`, and the Vikunja token of user `svc-alert-relay-d06`,
  `secret/v2/vikunja/alert-tokens/svc-alert-relay-d06#value`, outside `hubs/asyla/`
  (secrets-vault#46, 5a75b93, grants the role read on it; `deploy_role.py` names it by its full
  path), and its Loki query account `own/loki-clients/alert-relay#password` (`ALERT_RELAY_LOKI_KV`;
  created by `loki_accounts.py`, below; secrets-vault
  `policies/hubs/observability-d06-alert-relay.hcl` grants the role read on it). A record it
  cannot read switches that feature off at start, logged by category (never a value)
  (`alert-relay/relay.py`). The minting tool reads each record before it wraps the token (theOrg
  `scripts/vault_identity.py`), so `deploy_role.py` stops before the stack is touched while any of
  the six is not stored.
- emporia-collector (`EMPORIA_USERNAME_KV`, `EMPORIA_PASSWORD_KV`, plain paths, field `value`):
  `emporia-username`, `emporia-password`.
- scrape-proxy (`HOME_ASSISTANT_TOKEN_KV`, plain path, field `value`):
  `home-assistant-prometheus-token`.
- loki-gateway (`LOKI_CLIENTS_KV_PREFIX`, `LOKI_GATEWAY_ACCOUNTS`): every account of
  `loki-clients.toml`, `secret/hubs/asyla/own/loki-clients/<name>` (13 records). It reads each at
  start with its own wrapped token and checks each caller's Basic auth against it, push accounts
  for pushes only and query accounts for queries only (theOrg `loki-gateway/gateway.go`).
  `deploy_role.py` names one record per `[clients.<name>]` of `loki-clients.toml`, and
  `observability.sh` lists the same accounts in `LOKI_GATEWAY_ACCOUNTS` (a test checks the two
  agree). The `observability-d06` token role has had a `loki-gateway` component that reads these
  records since theorg #1276.
- prometheus-write-gateway (the same two settings, `PROMETHEUS_WRITE_GATEWAY_ACCOUNTS` in
  `observability.sh`): every account of `prometheus-write-clients.toml`,
  `secret/hubs/asyla/own/prometheus-write-clients/<name>` (1 record: `host-agent-ws02`, the Mini's
  Prometheus agent, push). Push accounts only, on `POST /api/v1/write` (theOrg DEPLOY.md, "Route
  modes").
- pushgateway-gateway (the same two settings, `PUSHGATEWAY_GATEWAY_ACCOUNTS`): every account of
  `pushgateway-clients.toml`, `secret/hubs/asyla/own/pushgateway-clients/<name>` (5 records:
  `deploy-all`, `functionality-test`, `identity-platform-dex-client-validity`,
  `memory-system-deploy-marker`, `staff-stack`, each push). Push accounts only, with `PUT`, `POST`
  and `DELETE` on `/metrics/job/<job>[/<label>/<value>...]`; a path holding `%2F` is 404, so a
  name with a slash goes in its `@base64` form.

Each gateway has its own prefix, token and accounts, so no password is shared across gateways, and
for each the same tests check that `deploy_role.py`'s records and `observability.sh`'s account list
match its registry. The `observability-d06` token role holds components
`prometheus-write-gateway` and `pushgateway-gateway` since the second vault apply (2026-11-23:
secrets-vault `7327bcb9`, vault-auth run 26910).

The gateways' account records are asyla's own: `loki_accounts.py` makes them, once, before the
first deploy that names them (a deploy without one stops at the mint), from the workstation:

```sh
cd ~/local/asyla && python3 projects/asyla-hosts/d06/apps/observability/loki_accounts.py [--registry loki|prometheus-write|pushgateway|all]
```

It runs theOrg's `scripts/loki_clients.py provision` (with `openbao.py`, at `deploy_role.py`'s
`TOOL_REV`, from the local theOrg clone) on each registry with asyla's hub token and its own
`LOKI_CLIENTS_KV_PREFIX`: `loki` (`loki-clients.toml`, `secret/hubs/asyla/own/loki-clients`),
`prometheus-write` (`prometheus-write-clients.toml`, `secret/hubs/asyla/own/prometheus-write-clients`)
and `pushgateway` (`pushgateway-clients.toml`, `secret/hubs/asyla/own/pushgateway-clients`);
`all`, the default, runs the three in that order with one sign-in, and the first that fails stops
the rest. For an account with no record it writes `username` and a generated `password` with
`cas=0`, so it never overwrites; a second run changes nothing (`<name>: exists`). It prints no
value. `--dry-run` prints the plan and contacts nothing.

`verify` is Loki's alone (its default registry): theOrg's `loki_clients.py verify` signs in on
Loki's routes only and has no check for the other two modes, so their anonymous refusals are
`observability.sh verify`'s (Upgrade, below).

Once loki-gateway is deployed and `loki.asyla.org` resolves, `loki_accounts.py verify` (same
command line, `verify` after the script) checks it end to end: it runs theOrg's
`scripts/loki_clients.py verify --url https://loki.asyla.org --ca-volume ''` with the same registry,
prefix, revision and hub token. It checks `/ready` with no account (200), a push and a query with
no account or a wrong password (401), the push account's push (204) and the query account's query
(200), each refused the other's scope (401), and that a line pushed with
`observability-check-push` reads back with `observability-check-query` (theOrg
`scripts/loki_clients.py` `verify` at `TOOL_REV`).
`--ca-volume ''` means no `--cacert`, so curl trusts its image's own store, which holds Let's
Encrypt's roots. It runs `docker run curlimages/curl` on the workstation and needs both check
accounts. `verify --dry-run` prints its plan and contacts nothing.

`loki_accounts.py verify --registry pushgateway` and `verify --registry prometheus-write` (asyla
#1268) check the two metrics gateways the same way, in the script itself: the account's password
(`deploy-all`, `host-agent-ws02`) is read with the hub token through the tool's `openbao.py`, and
each check is a `docker run curlimages/curl` with verified TLS and the account in curl's config on
stdin. pushgateway.asyla.org: `/ready` 200; `PUT /metrics/job/asyla_verify` with no account or a
wrong password 401, with `deploy-all` 200 or 202; its `DELETE` 202 (cleanup); `GET /metrics` 404
(not an admitted path; theOrg `loki-gateway/gateway.go` at `28b23389`). prometheus-write.asyla.org:
`POST /api/v1/write` with no account or a wrong password 401; with `host-agent-ws02` 204 for a
valid snappy-compressed empty WriteRequest and 204 for one hand-encoded sample,
`asyla_remote_write_verify{job="asyla-verify"} 1` at now (each body a valid remote write, so a
refusal is the account's, never the body's); and `/ready` 200 (prometheus-ingest's `/-/ready`).
The sample then stays in prometheus-ingest alone (its buffer keeps a day): `ingest-federate`
carries only theOrg's scrape-theorg jobs, and `asyla-verify` is not one of them, so it never
reaches the operations Prometheus.

## Deploy

From the workstation, on the LAN:

```sh
cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN -- python3 projects/asyla-hosts/d06/apps/observability/deploy_role.py
```

It pulls first (`observability.sh images`: every theOrg image, so a newer `latest` replaces the one
d06 has; pushgateway, pinned by version, only when missing), then reads the theOrg revision R the
images were built from (`observability.sh digests`, then the registry's provenance attestation of
each digest, every answer hash-checked against its digest; each digest must name exactly one commit,
the images must agree, every theOrg image and the provenance source must be on `REGISTRY`, and R must
be on the theOrg clone's `origin/main`), then mints the six wrapped tokens with theOrg's tool at
`TOOL_REV` (`deploy_role.py`; the tool runs with asyla's hub token, so it stays at a commit asyla
reviewed while the images follow `latest`) and starts the stack (`build_host.py d06 build --only apps --app observability --apply`, which runs
`observability.sh up`), then runs `OBSERVABILITY_REVISION=R observability.sh verify` on d06
(`--only apps` skips build_host's verify phase) and exits 1 when it fails; `deploy_role.py --dry-run` prints the plan and contacts
nothing (its header has the steps). `deploy_role.py --revision-only` (same command line) pulls,
reads R and checks the minting tool, prints `R = <sha>` and stops: no hub token, nothing minted,
nothing started. When theOrg changed `scripts/vault_identity.py` or `scripts/openbao.py` between
`TOOL_REV` and R, the deploy stops before the mint: read the change, then bump `TOOL_REV` in a
commit here. On a failure it says which step failed: the mint (nothing
started) or the start (the stack may be partly recreated: run `observability.sh status` and
`verify` on d06). If d06's installed `observability.sh` lists images of another tag, d06's
scripts tree is not master yet: after the merge, install it with `build_host.py d06 build --only
bootstrap --apply` (the error prints the whole command). `up` never pulls while a wrapped token is in its environment, since a pull
could outlast the token: a missing image there is an error. `up` recreates each tokened container
with its new token and leaves the others as they are unless their configuration changed.

A tokened service starts only when its token is set and not empty. Without it, `up` leaves that
service as it is, running or not, with a warning, and `verify` skips a tokened service that has
neither a container nor a token (a warning). So `observability.sh up` by hand, or a d06 build
without the tokens, starts the rest
and never fails on a component it cannot start. `restart` on d06 refuses unless all three tokens
are set, because `down` removes the tokened containers. After `down`, they come back only with a
deploy.

## Hardware alerts (asyla #610)

asyla's hardware checkers write `asyla_hw_problem{host,key,severity} 1` (one series per open
problem, severity `warning` or `urgent`) and `asyla_hw_check_last_run_timestamp_seconds{host,checker}`
into node_exporter textfiles. The job `asyla-hw` (`prometheus/scrape/asyla-hw.yml`) scrapes d01-d07
and vmh01-03 on `:9100` and keeps only `asyla_hw_*`; the rules (`prometheus/rules/asyla-hw.yml`)
alert through Alertmanager and alert-relay, which files a task in asyla/asyla-hosts (`alert_repo`),
named `HOST:hw:KEY`. Both directories are mounted by `compose.yml` on theOrg's deployer hooks
(DEPLOY.md at 04f3170).

| Checker | Host (served by) | Runs | Stale after |
| --- | --- | --- | --- |
| `nas-smart` | nas01 (d03's `smart.prom`) | hourly at :17, TrueNAS cron job 9 (hub `tools/export_nas_smart.py`) | 3h |
| `vmh-health` | vmh01-03 (`asyla-vmh-health.prom`) | hourly, host-maintenance's monitor (`vmh/health.sh`; its */15 schedule runs hourly on GitLab Free) | 3h |
| guests | d01-d07 (`~/maint/guest-health.prom`) | hourly, host-maintenance's monitor | 3h |

- `AsylaHwProblemUrgent`: fires at once; `AsylaHwProblemWarning`: after 10 minutes. Both keep firing
  15 minutes after the series goes, so a missed scrape does not close and reopen the task.
- `AsylaHwCheckerStale` (warning): a checker's last run is older than its limit above.
- `AsylaHwCheckerMissing` (warning, 30m): an `asyla-hw` exporter answers with no checker series, or
  there is no nas01 series at all. An exporter that does not answer is theOrg's `ScrapeTargetFailing`.

What to do: read the checker's own output for the key. nas01: `status.json` (host-maintenance's
`[[status]] nas01-smart`); a vmh: `vmh/apply.sh health NODE`; a guest: host-maintenance's
`maint_host.py check`. A stale or missing checker: is its schedule running, and is its textfile in
the node_exporter's textfile directory?

Check before a deploy (prom/prometheus:v2.55.1 is the base of theOrg's image at 04f3170):

```sh
docker run --rm -v "$PWD/d06/apps/observability/prometheus:/r:ro" -w /r/tests --entrypoint promtool prom/prometheus:v2.55.1 test rules asyla-hw_test.yml
```

theOrg's `scripts/check_deployer_rules.sh <image> d06/apps/observability/prometheus/rules
d06/apps/observability/prometheus/tests` also checks every rule has a `runbook_url`, with the image
d06 runs. A changed rule or scrape file reaches Prometheus at its next restart (a deploy).

## Restart behaviour

After a reboot of d06 or a Docker restart, alert-relay, emporia-collector and scrape-proxy start
again under `restart: unless-stopped` with a spent wrapping token. Each exits on it and Docker
starts it again: they loop until the next deploy. While alert-relay loops, Alertmanager's
deliveries fail, so no alert is filed or emailed, including the alerts about the loop. The trends
Prometheus gets no Home Assistant or Emporia data meanwhile; emporia-collector backfills what
Emporia still holds once it runs again. `verify` fails while any of the three loops. After any
reboot or Docker restart on d06, run the deploy.

A reboot comes without anyone deciding it: host-maintenance's `os` rota patches d06 on Fridays
(host-maintenance `setup/schedules.py:75-77` at f7b027c, `config/maintenance.toml:55`) and reboots
when the host says one is required (`remote/maint_host.py:301-306`). What notices the loop:

- now: host-maintenance's restart count, a "container ... restarted Nx since last check" warning
  for each of the three (`runner/maint.py:295-298`);
- the watchdog ping (`ALERT_WATCHDOG_PING="on"`): the healthchecks.io dead-man check, since
  Alertmanager's Watchdog reaches it only through alert-relay: a relay looping on a spent token
  sends no ping, and the check goes down.

The recovery is the deploy above (`deploy_role.py`), run by hand. theOrg's heal exists at f757911
(`scripts/heal_spent_tokens.py` and `heal.yml`, #324 and #326; DEPLOY.md "Recovery after reboot or
restart" names `--token-role observability-d06` for d06): it re-mints only the looping holders
without a deploy. d06 does not run it yet: which credential a scheduled heal mints with is open
with the operator.

## On, off, and what turns each on

On: alert tasks (alert-relay files each alert as a task in Vikunja, on `https://vikunja.asyla.org`,
the relay's `VIKUNJA_URL` default, with its Vikunja token; `ALERT_PROJECTS="asyla=170 theOrg=169"`
in `observability.sh`: 170 is asyla's child of theOrg's `Alerts` project and the default, as the
first entry, and 169 is theOrg's child, for an alert whose `alert_repo` label's owner part names
theOrg, case-insensitive; any other alert files in 170, and one in a project Vikunja refuses falls
back to 170 with a Routing note; theOrg alert-relay, and theOrg `DEPLOY.md` at b5bd228,
"alert-relay on d06 (asyla)". User `svc-alert-relay-d06` gets write on 169 from theOrg ticketing
8c1cc236 (theorg #1277), live after d06's next ticketing redeploy; every rule in theOrg's
`alerts/theorg/` carries `alert_repo: theOrg` at 04f31709 (theorg #1278); `ALERT_TEST_PROJECT=theOrg alert-test`, below, proves it), critical
alerts by email (Alertmanager's email piece posts them to alert-relay, which sends them to
`ALERT_EMAIL_TO` through `smtp.gmail.com:587` with the SMTP login), the delivery ping (alert-relay
pings its healthchecks.io check with `observability-delivery-ping-url` after each delivery and
after its Vikunja self-test, at start and then daily: success, or the check's `/fail` when Vikunja
refused; theOrg `alert-relay/relay.py` `record_delivery`, `record_selftest`), the Watchdog ping
(Alertmanager's watchdog piece, `ALERT_WATCHDOG_PING="on"` in `observability.sh`: the always-firing
Watchdog goes to alert-relay's `/watchdog` every 5 to 6 minutes, and the relay pings the
healthchecks.io check with `observability-watchdog-ping-url`; `""` turns it off), the trends Home
Assistant job (through scrape-proxy), emporia-collector, and Vector's container-log pipeline
(`VECTOR_DOCKER_LOGS`, with the Docker socket mounted as theOrg's `compose.docker-socket.yml` does):
this stack's own container logs to Loki over plain HTTP inside `observability-net`, and their
`CHRONICLE_EPISODE` lines to memory-system's Vector on the Mini. At 7572365 it was off, because its
Loki sink named `/etc/loki-ca/root_ca.crt`; at f757911 no Vector file names a CA or has a tls block.

alert-relay's log lines are on too: for an alert with a `logql` annotation the relay runs it
against `LOKI_QUERY_URL`, here Loki itself at `http://loki:3100` inside `observability-net`, from
`LOGQL_LOOKBACK_SECONDS` (900) before the alert's start to now, and puts the newest lines in the task it
opens (theOrg `alert-relay/relay.py` `log_section` at b5bd228). Loki has `auth_enabled: false`
(theOrg `loki-config-http.yaml` at b5bd228) and plain HTTP, as vector-1 and Prometheus reach it.
The relay fetches only with its query password as well (`loki_password`, `ALERT_RELAY_LOKI_KV`),
which it sends as Basic auth `alert-relay:<password>`: Loki ignores it, and loki-gateway would
check it were the relay to query through the gateway. At b5bd228 the only theOrg rule with a `logql` annotation is
`loki-rules/selftest.yml` (`LokiRulerSelfTest`), so today lines appear for the self-tests
(`alert-test`, below) and any later rule with one.

The Docker socket is bound into `vector-1` and `docker-state-exporter-1` as theOrg's
`compose.docker-socket.yml` binds it. The bind's `:ro` does not make the Docker API read-only:
whatever can connect to the socket has the whole API. Vector's only inputs are `internal_metrics`
and `docker_logs` limited to compose project `observability` (theOrg `vector.toml` and
`vector-docker-logs.toml` at f757911). A socket proxy in front of it would be theOrg's change.

The delivery ping and the Vikunja token go on together. Holding the ping URL without a token that
can read project 170, the relay's self-test fails at its first start and pings the check's
`/fail`, which takes the check down and pages (theOrg `alert-relay/relay.py` `delivery_selftest`,
`record_selftest`). So user `svc-alert-relay-d06`, its token record and the vault grant
(secrets-vault#46) come before the deploy that names them. To turn the ping off, drop
`ALERT_RELAY_DELIVERY_PING_KV` from `compose.yml` and the record from `deploy_role.py`'s
`IDENTITIES`, and want `delivery_ping_url=0` in `check_tokened` and no `check_delivery`.

`ALERT_PROJECTS` goes to alert-relay only, as in theOrg's `docker-compose.yml` at b5bd228.
`GITEA_URL`, `GITEA_ALERT_REPO`, `ALERT_REPOS` and `ALERT_RELAY_FORGE_KV` are gone: the relay no
longer reads them and has no Gitea fallback (theOrg `DEPLOY.md` at b5bd228).

The Gitea alert side was retired on 2026-11-07, on the operator's go-ahead (asyla hub backlog
`2026-11-07-d06-retire-the-gitea-alert-side`). secrets-vault#48 dropped the vault read grants on
`secret/hubs/asyla/observability-alert-relay-gitea-token`. `asyla/alerts` is archived and kept
with its 5 closed issues, which other backlog items cite. The gitea user `asyla-alert-relay` and
its team `asyla/alert-filers` are deleted, and the user's token with them. The vault record is
left holding that dead token: only root can delete it.

The Loki gateway is on (theOrg's option B, asyla #1268), so callers off this host push logs to and
query Loki at `https://loki.asyla.org`, each with its own account. It is theOrg's `loki-gateway`
service (`compose.yml`) with d06's settings: `LOKI_GATEWAY_TLS` off, so it serves plain HTTP and
needs no step-ca, provisioner or `loki-ca` volume (theOrg `loki-gateway/main.go`, `loadConfig`
returns before them); no published port; the accounts of `loki-clients.toml`, read from
`secret/hubs/asyla/own/loki-clients/<name>` with its own wrapped token (Secrets, above). TLS ends
at d06's Caddy, which reaches the gateway on `loki-edge` only (Names, above). alert-relay and
Vector stay on `loki:3100` inside the stack. A replica runs no gateway: it would read production's OpenBao. The volumes `loki-tls` and
`loki-gateway-auth` on d06, from the first deploy, are unused; deleting them is the operator's
decision.

The two metrics gateways (theOrg's route modes, asyla #1268 items 3 and 4) are the same image
with `LOKI_GATEWAY_MODE` set, each with its own token, accounts and prefix (Secrets, above), on
`observability-net` (OpenBao), `loki-edge` (Caddy) and its own upstream's network:

- prometheus-write-gateway (`remote-write`), `https://prometheus-write.asyla.org`: admits only
  `POST /api/v1/write` with a push account and forwards it to prometheus-ingest on `ingest`;
  `/ready` is open and forwarded to the upstream's `/-/ready`; every other path is 404,
  Prometheus's query, admin and federate paths included. It starts once prometheus-ingest is
  healthy (`depends_on`), and its healthcheck is theOrg's `/loki-gateway healthcheck` (`GET
  /ready`, so prometheus-ingest's `/-/ready`).
- prometheus-ingest is the ingest Prometheus (theOrg DEPLOY.md, "Where the writes go";
  `compose.ingest.yml` at `04f31709`): the operations image with `PROMETHEUS_MODE=ingest`
  (`/etc/prometheus/ingest.yml`, globals only: no scrape job and no rule), its receiver on, its
  only network `ingest`, no port, 1 day or 2 GB kept, whichever first: a buffer, not history. Its
  data is under `OBSERVABILITY_ROOT` like the other Prometheus data. It reads nothing off the host,
  so it runs on a replica too (empty there: no gateway writes to it).
- the operations Prometheus federates it: `FEDERATE_INGEST=true` with
  `FEDERATE_INGEST_HOST=prometheus-ingest` and `FEDERATE_INGEST_PORT=9090` makes theOrg's
  entrypoint write the job `ingest-federate` (`/federate` with one `match[]` per job name in its
  `scrape-theorg/`, `honor_labels`), whatever `MONITOR_THEORG` says; its own receiver stays off.
  With `MONITOR_THEORG` on too the entrypoint refuses to start unless `THEORG_SCRAPE=false`, which
  d06 sets (theOrg's rules, below). So the remote-write path end to end:
  the Mini's agent writes to `https://prometheus-write.asyla.org` with its account, Caddy hands it
  to prometheus-write-gateway on `loki-edge`, the gateway checks the account (its record read from OpenBao at start) and
  forwards to `prometheus-ingest:9090` on `ingest`, and the operations Prometheus reads it from
  there by `ingest-federate`. `observability.sh verify` checks prometheus-ingest's `/-/healthy`
  from `prometheus-1` on `ingest`, the `ingest-federate` target up, and the gateway's `/ready` 200;
  `loki_accounts.py verify --registry prometheus-write` checks a write with the account (204,
  above).
- pushgateway-gateway (`pushgateway`), `https://pushgateway.asyla.org`: admits only `PUT`, `POST`
  and `DELETE` on `/metrics/job/...` with a push account and forwards it to `pushgateway:9091` on
  `push`. The pushgateway is on `push` alone (off `observability-net`, no published port), so
  this gateway is the one way in; the operations Prometheus scrapes it there by service name
  (theOrg's `prometheus/scrape-stack/pushgateway.yml`).
- theOrg's rules: `MONITOR_THEORG=true` (on since the Mini's agent, theorg #1269, pushes, 2026-11-23;
  asyla #1268) makes theOrg's entrypoint copy its `alerts-theorg/` into the rules the operations
  Prometheus reads, so they run on the federated series. Every one carries `alert_repo: theOrg`,
  so alert-relay files it in 169. `THEORG_SCRAPE=false` leaves out `scrape-theorg/` (those jobs
  scrape `host.docker.internal`, which here is d06, not the Mini). `MONITOR_THEORG` also copies one
  communications scrape set: `COMMUNICATIONS_REMOTE=true` (theOrg's communications-placement is
  d06) picks `remote/`, the one job `chat-api` at `theorg.asyla.org:443` over verified https, so
  `ChatApiUnavailable` watches d06's chat-api; `local/`'s four `host.docker.internal` jobs would
  read down here (chat-api and the NATS exporter are published on 127.0.0.1 only). From d06's
  `observability-net`, blackbox-exporter's `http_2xx` probe of `https://theorg.asyla.org/metrics`
  read success, 200, TLS (2026-11-23). verify wants a `chat-api` target (`OTHER_STACK_JOBS`) but
  does not judge its health: that needs communications and internal-access, which d06's build
  starts after this stack, and a replica has neither; `ChatApiUnavailable` alerts on it. verify
  also wants theOrg's `chat-api` rule group loaded from `alerts-enabled/` (`check_theorg_rules`, as
  theOrg's `deploy.yml` does). The Mini's own operations Prometheus still loads the same rules
  (theOrg `deploy.yml` at 04f31709 names `compose.theorg.yml`), so until theOrg drops them there a
  theOrg alert can be raised on both hosts. Six of theOrg's rules use `absent()` on a
  series only the Mini's agent writes (theOrg `DEPLOY.md` at 04f31709, "theOrg's rules without its
  jobs"), so an outage of that agent fires them here. Before the switch each of the six read
  present in the operations Prometheus, and no federated `up{host="ws02"}` read 0 (2026-11-23).

Off here and nowhere else:

- chat-api delivery: `CHAT_API_URL` is empty (alert-relay posts no chat message); theOrg's, not
  asyla's. chat-api itself is scraped ("theOrg's rules", above).

## Upgrade

The stack follows theOrg's `latest`: a deploy (above) moves it to the newest images, and the
tokened services move only through a deploy. The deploy prints the revision R it read from the
images' provenance (`theOrg observability revision R`), and `verify` prints it again. A pin is a
commit here that sets `OBSERVABILITY_TAG`'s default in `observability.sh` to a theOrg `main` sha
whose images are published; the deploy then stops unless the images' provenance names that sha.
After a deploy to a new R, check `compose.yml` against theOrg's `docker-compose.yml` at R (nothing
checks that before the start; `verify` after it catches a job theOrg drops or renames, as "no
target", but not a service theOrg adds that `compose.yml` lacks), and what `check_tokened`,
`check_watchdog` and `check_delivery` read against theOrg at R: the relay's metric names
(`alert-relay/relay.py`) and the watchdog piece's receiver name and route
(`alertmanager-pieces/watchdog/`). `verify` checks the services
are healthy, Prometheus is healthy with one Alertmanager, `docker_container_running` on `9099`,
the trends retention is a size, the three blackbox self-probes, every target of the operations
Prometheus (below), and (not on a replica) that Vector's container logs reach Loki: lines labelled
`forwarder="vector-observability"` in the last 10 minutes, read from inside the network
(`vector-1`'s wget to `loki:3100`). Each waits up to `VERIFY_WAIT_S`, the targets up to
`SCRAPE_GRACE_S` after the self-probes. For each tokened service whose container exists, it also
checks that the service read its secrets, waiting once more up to `VERIFY_WAIT_S` for all three and
at least `SCRAPE_GRACE_S` (75 s, one scrape and some) for each:

- scrape-proxy: the trends Prometheus (`9107`) reads `up{job="asyla-home-assistant"}` 1 (theOrg
  `trends/scrape/asyla-home-assistant.yml`). The proxy answers 503 without its vault token and 502
  when Home Assistant refuses the token (theOrg `scrape-proxy/proxy.py`), so 1 means Home
  Assistant took the token it read.
- emporia-collector: the trends Prometheus reads `sum(emporia_collector_openbao_failure)` 0 and
  `count(emporia_channel_info)` 1 or more (job `emporia`, theOrg `trends/scrape/emporia.yml`). Its
  `up` alone proves nothing: the collector serves its metrics before it reads OpenBao and retries
  the login forever (theOrg `emporia-collector/collector.py` at f757911). The failure gauge is 0 in
  every category after an OpenBao read or a renewal that worked (the renewal since #325); the
  channel names appear only once Emporia took the login and the collector read the channels.
- alert-relay: its own metrics (`9111`) read `alert_relay_secret_present` 1 for
  `delivery_ping_url`, `loki_password` and `vikunja_token`, for `smtp_username` and
  `smtp_password` (with `ALERT_EMAIL_TO`) and for `watchdog_ping_url` (with `ALERT_WATCHDOG_PING`)
  (theOrg `alert-relay/relay.py`). That it holds them, not that Gmail takes the login; that the
  token can read project 170 is `check_delivery`'s; that a `logql` query returns lines is
  `alert-test`'s.
- the three gateways (`check_gateway`), each whose container exists, asked from inside the stack
  (`vector-1`'s wget to `<gateway>:3100`): `/ready` with no account, and an anonymous request on
  its one admitted route must be 401 (the account check comes before the upstream: theOrg
  `loki-gateway/gateway.go`). loki-gateway: `/ready` 200, `GET /loki/api/v1/labels` 401;
  prometheus-write-gateway: `/ready` 200 (prometheus-ingest's `/-/ready`),
  `POST /api/v1/write` 401; pushgateway-gateway: `/ready` 200,
  `PUT /metrics/job/verify` 401. vector-1's wget is GNU Wget (theOrg's `Dockerfile.vector` installs
  Debian's `wget` into `timberio/vector:0.56.0-debian`, which has no busybox; Wget 1.25.0 there
  lists `--method` and `--body-data`, checked 2026-11-22), so a POST or PUT is
  `--method=<M> --body-data=` (an empty body). That each account gets in with its own password is
  `loki_accounts.py verify`'s, with `--registry` for each gateway.

With `ALERT_WATCHDOG_PING` on and alert-relay running, verify then checks the Watchdog's ping
(`check_watchdog`): the running Alertmanager loaded the watchdog piece (its `/api/v2/status`
configuration has the receiver `watchdog` and a route to it; Alertmanager shows webhook URLs there
as `<secret>`), and the relay's `alert_relay_watchdog_pings_total{result="sent"}` is 1 or more, a
ping the check's endpoint answered 2xx. A healthchecks.io check that never got a ping stays "new"
and never alerts, so that first ping arms it. It waits until `WATCHDOG_WAIT_S` (450 s) after the
later `.State.StartedAt` of `alertmanager-1` and `alert-relay-1`: Alertmanager keeps its last send
in `alertmanager-data` across a restart and sends again only once `repeat_interval` (5m) has passed,
at a `group_interval` (1m) tick (theOrg `alertmanager-pieces/watchdog/route.yml`). A later verify
reads once. The relay's `error` count alone is a failure.

With alert-relay running, verify then checks its Vikunja self-test and the delivery ping
(`check_delivery`), from the relay's own metrics (`9111`; a series the relay has not counted yet
reads 0): `alert_relay_delivery_selftests_total{result="ok"}` 1 or more and `{result="failed"}` 0;
`alert_relay_delivery_pings_total{kind="success",result="sent"}` 1 or more, and
`{kind="fail",result="sent"}` and `{kind="fail",result="error"}` (a `/fail` ping the endpoint did
not take) 0; and `alert_relay_delivery_failures_total{sink="vikunja"}` (an alert the relay did not
get into Vikunja) 0. Holding the ping URL, the relay runs the self-test as it starts: its token
reads project 170 (the `ALERT_PROJECTS` default), a GET, which passes on HTTP 200 (theOrg
`alert-relay/relay.py` `delivery_selftest`, `selftest_loop`), and a pass pings the check's URL, a
ping its endpoint took (`_send_ping`). So it proves that the token can read project 170 and the
path to Vikunja, not that it can write there: verify creates no task. `alert-test` (below) proves
the write. That first ping also arms the healthchecks.io check. It waits until `DELIVERY_WAIT_S`
(180 s) after `alert-relay-1`'s `.State.StartedAt` (the read may take 20 s, once more after a 401
and up to 3 more on a locked database; an errored ping is tried again after 5, 10, 20 s ...). A
later verify reads once. A failed self-test, a `/fail` ping (sent or errored) or a failed Vikunja
delivery since the start fails at once: a counter never falls. The counters cover the relay's
whole life, so once one failure is counted, every later standalone verify fails until alert-relay
is recreated. A deploy always recreates it, since it passes a new wrapped token; so once the cause
is fixed, redeploy (`deploy_role.py`) to clear it.

`observability.sh alert-test` proves the write and the log lines, on d06 by hand: it pushes one
test line under `{job="asyla-alert-test"}` into Loki (`loki-1`'s own wget to `127.0.0.1:3100`),
adds one `info` alert with `amtool` in `alertmanager-1` whose `logql` annotation selects that
line, then waits for alert-relay's log line `alert-relay opened task <id> in project 170 (<fp>)`,
requires `alert_relay_logql_queries_total{result="lines"}` (`9111`) to have risen by then, and
waits for its `closed` line for that task (theOrg `alert-relay/relay.py`; modelled on theOrg
`scripts/alert_routing_selftest.sh` at b5bd228).
The email route matches `severity="critical"` only (theOrg `alertmanager-pieces/email/route.yml`),
so an `info` alert sends no email. From the workstation, on the LAN:

```sh
ssh -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/docker_rsa docker@d06 '~/scripts/d06/apps/observability/observability.sh alert-test'
```

With `ALERT_TEST_PROJECT=<name>` in the environment (switches take no arguments), the alert also
carries `alert_repo="<name>/observability"` and the task must open in that `ALERT_PROJECTS` entry's
project, not the default; a name not listed is refused, naming the entries. The theOrg proof (169,
once theorg #1277's grant is live on d06):

```sh
ssh -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/docker_rsa docker@d06 'ALERT_TEST_PROJECT=theOrg ~/scripts/d06/apps/observability/observability.sh alert-test'
```

The self-probes and the trends readings count only samples taken after the containers involved
started: `timestamp(...) > S` in the query, S the later `.State.StartedAt` of the service and the
Prometheus that holds the samples (for the self-probes, `prometheus-1` and `blackbox-exporter-1`).
A new image recreates both Prometheus, and a Prometheus that stops writes no staleness markers,
so until its first scrape after the restart an instant query can return a sample from before it.

The targets check reads the operations Prometheus's active targets (`127.0.0.1:9090/api/v1/targets`)
and needs each to read health `up` at a scrape (`lastScrape`) after S, S the later
`.State.StartedAt` of `prometheus-1` and the job's service, and each job of `STACK_JOBS`
(`observability.sh`) to have a target. `STACK_JOBS` lists the jobs the prometheus image of the
running revision (R) runs here: theOrg's `prometheus/scrape-stack/*.yml` (alert-relay, alertmanager,
loki, prometheus-trends, pushgateway, scrape-proxy, vector), the two optional pieces'
(`scrape-optional/blackbox-exporter.yml`: also blackbox-selftest; `docker-state-exporter.yml`) and
`base_config.py`'s `prometheus`. A job whose service is not expected here (a replica's, or a tokened
service never deployed) is left out. This is theOrg's deploy step "Verify this stack's own scrape
targets are up" (#327), which reads the jobs from its checkout; d06 has only the images, so an
deploy to a new R checks `STACK_JOBS` against theOrg's `prometheus/` at R (a "no target" failure
says so). A job theOrg adds there
and `STACK_JOBS` misses is still checked (S from `prometheus-1` alone); a job it drops fails as "no
target". The trends Prometheus's targets are not checked (Known limits: three of its jobs read 0
from d06).

## Known limits

- No backup yet. A lost `/mnt/docker/Observability` is lost; the app has no `restore` switch
  (`restore = false` in `host.toml`).
- Reach from d06 was read from the host, not from inside a container (2026-11-03):
  `vault.asyla.org` and `homeassistant.asyla.org` answered 200, `smtp.gmail.com:587` was open.
- The trends Prometheus starts empty on d06. theOrg re-runs its `emporia-history` to fill it.
- The Mini's emporia-collector keeps running until d06's trends writes, then theOrg turns it off.
- From d06 (10.0.0.65) the trends jobs `asyla-d03-node`, `asyla-d07-node` and `asyla-switch-snmp`
  read `up=0`. The ports they scrape admit only 10.0.0.150 (the Mini): `d03/host.toml:27`,
  `d07/host.toml:33` and `d07/host.toml:47`. A follow-up widens those allow lists to the LAN
  subnet; d03 and d07 are not changed here.
- d06's `update_all.sh` reports this app as FAIL. It runs `backup`, which this app does not have,
  and `update`, which needs the pull token from the workstation. This matches ticketing's `update`.
- theOrg has no account check for the remote-write and pushgateway modes (`loki_clients.py
  verify` is Loki's only), so `observability.sh verify` checks only their anonymous refusals.
- `VECTOR_DOCKER_LOGS` also loads theOrg's `to_memory_system` sink: `CHRONICLE_EPISODE` lines to
  `CHRONICLE_VECTOR_ADDRESS` (10.0.0.150:6000, the Mini's memory-system). On d06 it forwards none (a
  2026-11-03 read: 0 in 2 h from all 11 containers; `docker_logs` reads only project
  `observability`). A separate off switch would be theOrg's change.
