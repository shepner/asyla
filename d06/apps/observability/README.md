# observability (d06)

theOrg's observability stack: Loki, Prometheus, the trends Prometheus, Alertmanager,
alert-relay, emporia-collector, scrape-proxy, the pushgateway, Vector, docker-state-exporter and
blackbox-exporter, without theOrg's loki-gateway (On, off, below). asyla deploys it here from
theOrg observability `DEPLOY.md`, last read at main `f7579118fdac5d90101a5ec6698200ae2c9d836f`
(#327; design 4 since #311). The images follow theOrg's `latest` (operator 2026-11-03: "keep
'latest' no matter what. Anything running older images will need to update"); the revision is read
from the images' provenance at deploy: `deploy_role.py` pulls every image on d06, reads the theOrg
commit each was built from out of the provenance attestation the registry holds for the digest d06
pulled, and stops, with nothing minted or started, when one is missing, names no theOrg commit, or
the images disagree. It prints that revision and passes it to `verify`.

- `compose.yml`: theOrg's `docker-compose.yml` with `compose.docker-socket.yml` and
  `compose.blackbox.yml` folded in (the Docker-socket and blackbox pieces are on). `MONITOR_THEORG`
  is off: credential-probe, the Ollama log and the other stacks' jobs and rules are theOrg's, not
  here. Project, container, volume and network names are theOrg's. No build sections.
- `observability.sh`: `up`, `down`, `restart`, `verify`, `update`, `pull`, `images`, `logs`,
  `status`, `digests`, `alert-test`. It names the tag (`latest`), sets the settings, creates the
  data directories and keeps the start order. A replica (a host with `[replica] of = "d06"`) runs
  only the services with nothing to reach off the host: no alert-relay, emporia-collector,
  scrape-proxy or Vector.
- `deploy_role.py`: the deploy (below): pulls, mints the three wrapped tokens, starts the stack.
- `loki_accounts.py` and `loki-clients.toml`: asyla's own Loki accounts for d06 (alert-relay's
  query account), created once in OpenBao (Secrets, below).
- Tests, offline: `python3 scripts/tests/test_d06_deploy_role.py` and
  `python3 scripts/tests/test_d06_loki_accounts.py`.
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
  trends `9107` (container `9090`), Alertmanager `9093`, pushgateway `9091`, alert-relay `9111`,
  Vector `9598`, docker-state-exporter `9099`. Loki (`3100`, plain HTTP, reached in the stack as
  `loki:3100`), alert-relay's health port, emporia-collector (`9108`), scrape-proxy (`9119`) and
  blackbox-exporter are not published.
- Names (`caddy-internal-d06`, LAN only): `prometheus.asyla.org`, `alertmanager.asyla.org` and
  `prometheus-trends.asyla.org`. They are the external URLs Prometheus and Alertmanager put in
  links (`PROMETHEUS_EXTERNAL_URL`, `ALERTMANAGER_EXTERNAL_URL` in `observability.sh`). The proxy
  entries belong to the asyla `internal-access` repo (`hosts/d06`).

## Secrets

No secret is in any file, volume or container environment, here or on the host (core
`secrets.md` SEC-5 and SEC-7; the operator, 2026-11-03: "secrets are to live in the vault").
Nothing in this directory writes a value anywhere. Values reach `observability.sh` only as named
environment variables that the workstation sends at use over SSH stdin (build_host.py):

- `OBSERVABILITY_REGISTRY_PULL_TOKEN` (`pull_token_env = "THEORG_REGISTRY_PULL_TOKEN"` in
  `d06/host.toml`): the `theorg-registry` read:package token for the image pulls. The credential
  helper answers Docker from it under a throwaway `DOCKER_CONFIG`; nothing is stored.
- `ALERT_RELAY_OPENBAO_WRAPPED_TOKEN`, `EMPORIA_OPENBAO_WRAPPED_TOKEN`,
  `SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN` (`start_env_optional` in `d06/host.toml`): each a
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

The Loki account record is asyla's own: `loki_accounts.py` makes it, once, before the first
deploy that names it (a deploy without it stops at the mint), from the workstation:

```sh
cd ~/local/asyla && python3 projects/asyla-hosts/d06/apps/observability/loki_accounts.py
```

It runs theOrg's `scripts/loki_clients.py provision` (with `openbao.py`, at `deploy_role.py`'s
`TOOL_REV`, from the local theOrg clone) on `loki-clients.toml` with asyla's hub token and
`LOKI_CLIENTS_KV_PREFIX=secret/hubs/asyla/own/loki-clients`: for an account with no record it
writes `username` and a generated `password` with `cas=0`, so it never overwrites; a second run
changes nothing (`<name>: exists`). It prints no value. `--dry-run` prints the plan and contacts
nothing.

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
be on the theOrg clone's `origin/main`), then mints the three wrapped tokens with theOrg's tool at
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

On: alert tasks (alert-relay files each alert as a task in Vikunja project 170, asyla's child of
theOrg's `Alerts` project, on `https://vikunja.asyla.org`, the relay's `VIKUNJA_URL` default, with
its Vikunja token; `ALERT_PROJECTS="asyla=170"` in `observability.sh` has one entry, the default,
so every alert goes there; theOrg `DEPLOY.md` at b5bd228, "alert-relay on d06 (asyla)"), critical
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
which it sends as Basic auth `alert-relay:<password>`: Loki ignores it today, and a d06 gateway
under option B would check it. At b5bd228 the only theOrg rule with a `logql` annotation is
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

Off here and nowhere else:

- The Loki gateway, so any log push or query from off this host (theOrg lead's option A for d06,
  2026-11-03). theOrg's f757911 gateway reads its accounts from OpenBao with its own wrapped token
  and signs its TLS leaf from step-ca's `loki` provisioner; d06 has neither a loki-gateway
  identity in the `observability-d06` token role nor a provisioner or step-ca name of its own, so
  `compose.yml` leaves the service out and `deploy_role.py` mints no token for it. `up` removes
  the container an earlier deploy left (`loki-gateway-1`) with `--remove-orphans`. On: theOrg's
  option B: a d06 loki-gateway component and its provisioner-password record in secrets-vault
  (under `hubs/asyla/`), a `loki-d06` provisioner in certificate-management, and a LAN name for
  step-ca; then the service in `compose.yml` with d06's settings and its line in `deploy_role.py`.
  The volumes `loki-tls` and `loki-gateway-auth` on d06, from the first deploy, are unused now;
  deleting them is the operator's decision. With the gateway on, alert-relay's `LOKI_QUERY_URL`
  would name it, as theOrg's `docker-compose.yml` at b5bd228 does (the gateway on
  `host.docker.internal:3100`), and the gateway would check the relay's account
  (`loki-clients.toml`).
- chat-api: `CHAT_API_URL` is empty; theOrg's, not asyla's.

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
- With no gateway, no caller off this host can push logs to or query Loki (option B, above).
- `VECTOR_DOCKER_LOGS` also loads theOrg's `to_memory_system` sink: `CHRONICLE_EPISODE` lines to
  `CHRONICLE_VECTOR_ADDRESS` (10.0.0.150:6000, the Mini's memory-system). On d06 it forwards none (a
  2026-11-03 read: 0 in 2 h from all 11 containers; `docker_logs` reads only project
  `observability`). A separate off switch would be theOrg's change.
