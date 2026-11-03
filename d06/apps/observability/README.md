# observability (d06)

theOrg's observability stack: Loki, Prometheus, the trends Prometheus, Alertmanager,
alert-relay, emporia-collector, scrape-proxy, the pushgateway, Vector, docker-state-exporter and
blackbox-exporter, without theOrg's loki-gateway (On, off, below). asyla deploys it here from
theOrg observability `DEPLOY.md` at main `f7579118fdac5d90101a5ec6698200ae2c9d836f` (#327; design
4 since #311), using theOrg's published images of that sha. They were not read from the registry
for f757911 when this pin was written: `deploy_role.py`'s `images` step pulls them on d06 and
stops, with nothing minted or started, when one is missing.

- `compose.yml`: theOrg's `docker-compose.yml` with `compose.docker-socket.yml` and
  `compose.blackbox.yml` folded in (the Docker-socket and blackbox pieces are on). `MONITOR_THEORG`
  is off: credential-probe, the Ollama log and the other stacks' jobs and rules are theOrg's, not
  here. Project, container, volume and network names are theOrg's. No build sections.
- `observability.sh`: `up`, `down`, `restart`, `verify`, `update`, `pull`, `images`, `logs`,
  `status`. It pins the tag, sets the settings, creates the data directories and keeps the start
  order. A replica (a host with `[replica] of = "d06"`) runs only the services with nothing to reach
  off the host: no alert-relay, emporia-collector, scrape-proxy or Vector.
- `deploy_role.py`: the deploy (below): pulls, mints the three wrapped tokens, starts the stack.
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
  response-wrapped, single-use token that `deploy_role.py` mints from the `observability-d06`
  token role (theOrg `scripts/vault_identity.py` at the pinned tag). The component unwraps it once
  at start and holds the real token in memory, so what Docker keeps in the container's config is
  a spent wrapping token. A wrapping token lapses 300 s after it is minted.

Each component reads only the records its role policy grants (secrets-vault
`policies/hubs.toml`, `[token_roles.observability-d06.components]`), all under
`secret/hubs/asyla/`, named in `compose.yml`:

- alert-relay (`ALERT_RELAY_<X>_KV`, `PATH#FIELD`): `smtp-relay-username#value`,
  `smtp-relay-password#value`, `observability-alert-relay-gitea-token#value`,
  `observability-watchdog-ping-url#value`, `observability-delivery-ping-url#value`. A record it
  cannot read switches that feature off at start, logged by category (never a value)
  (`alert-relay/relay.py`).
- emporia-collector (`EMPORIA_USERNAME_KV`, `EMPORIA_PASSWORD_KV`, plain paths, field `value`):
  `emporia-username`, `emporia-password`.
- scrape-proxy (`HOME_ASSISTANT_TOKEN_KV`, plain path, field `value`):
  `home-assistant-prometheus-token`.

## Deploy

From the workstation, on the LAN:

```sh
cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN -- python3 projects/asyla-hosts/d06/apps/observability/deploy_role.py
```

It pulls first (`observability.sh images`), then mints the three wrapped tokens and starts the
stack (`build_host.py d06 build --only apps --app observability --apply`, which runs
`observability.sh up`), then runs `observability.sh verify` on d06 (`--only apps` skips build_host's
verify phase) and exits 1 when it fails; `deploy_role.py --dry-run` prints the plan and contacts
nothing (its header has the steps). On a failure it says which step failed: the mint (nothing
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
- once the watchdog ping is on (`ALERT_WATCHDOG_PING`): the healthchecks.io dead-man, since
  Alertmanager's Watchdog reaches it through alert-relay.

The recovery is the deploy above (`deploy_role.py`), run by hand. theOrg's heal exists at f757911
(`scripts/heal_spent_tokens.py` and `heal.yml`, #324 and #326; DEPLOY.md "Recovery after reboot or
restart" names `--token-role observability-d06` for d06): it re-mints only the looping holders
without a deploy. d06 does not run it yet: which credential a scheduled heal mints with is open
with the operator.

## On, off, and what turns each on

On: critical alerts by email (Alertmanager's email piece posts them to alert-relay, which sends
them to `ALERT_EMAIL_TO` through `smtp.gmail.com:587` with the SMTP login), the trends Home
Assistant job (through scrape-proxy), emporia-collector, and Vector's container-log pipeline
(`VECTOR_DOCKER_LOGS`, with the Docker socket mounted as theOrg's `compose.docker-socket.yml` does):
this stack's own container logs to Loki over plain HTTP inside `observability-net`, and their
`CHRONICLE_EPISODE` lines to memory-system's Vector on the Mini. At 7572365 it was off, because its
Loki sink named `/etc/loki-ca/root_ca.crt`; at f757911 no Vector file names a CA or has a tls block.

The Docker socket is bound into `vector-1` and `docker-state-exporter-1` as theOrg's
`compose.docker-socket.yml` binds it. The bind's `:ro` does not make the Docker API read-only:
whatever can connect to the socket has the whole API. Vector's only inputs are `internal_metrics`
and `docker_logs` limited to compose project `observability` (theOrg `vector.toml` and
`vector-docker-logs.toml` at f757911). A socket proxy in front of it would be theOrg's change.

Off here and nowhere else:

- Alert issues on the forge: the forge token record is not stored. On: store
  `observability-alert-relay-gitea-token`, then deploy (the relay reads its records at start).
- Delivery ping: same, record `observability-delivery-ping-url`.
- Watchdog ping: record `observability-watchdog-ping-url`, and `ALERT_WATCHDOG_PING="on"` in
  `observability.sh` (one line; alert-relay already names the record). Then deploy.
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
  deleting them is the operator's decision.
- alert-relay's log lines in issues: `LOKI_QUERY_URL` is empty and `ALERT_RELAY_LOKI_KV` is not
  set. Loki in the stack needs no account, but the relay fetches lines only when `LOKI_QUERY_URL`
  and its query password are both set (theOrg `alert-relay/relay.py` `log_section` and its start
  line, "log lines: off"), so `http://loki:3100` alone changes nothing. On: the password record
  (secrets-vault#37, `secret/hubs/asyla/own/loki-clients/alert-relay#password`, readable after its
  vault-auth apply) in `ALERT_RELAY_LOKI_KV`, and `LOKI_QUERY_URL` set (the gateway under option
  B).
- chat-api: `CHAT_API_URL` is empty; theOrg's, not asyla's.

## Upgrade

Change `OBSERVABILITY_TAG` in `observability.sh` to a theOrg `main` sha whose images are published,
check `compose.yml` against theOrg's `docker-compose.yml` at that sha, commit, then deploy (above):
the tokened services move to the new images only through a deploy. `verify` checks the services
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
- alert-relay: its own metrics (`9111`) read `alert_relay_secret_present{secret="smtp_username"}`
  and `{secret="smtp_password"}` 1 (theOrg `alert-relay/relay.py`). That it holds the login, not
  that Gmail takes it.

The self-probes and the trends readings count only samples taken after the containers involved
started: `timestamp(...) > S` in the query, S the later `.State.StartedAt` of the service and the
Prometheus that holds the samples (for the self-probes, `prometheus-1` and `blackbox-exporter-1`).
A tag change recreates both Prometheus, and a Prometheus that stops writes no staleness markers,
so until its first scrape after the restart an instant query can return a sample from before it.

The targets check reads the operations Prometheus's active targets (`127.0.0.1:9090/api/v1/targets`)
and needs each to read health `up` at a scrape (`lastScrape`) after S, S the later
`.State.StartedAt` of `prometheus-1` and the job's service, and each job of `STACK_JOBS`
(`observability.sh`) to have a target. `STACK_JOBS` lists the jobs the prometheus image of
`OBSERVABILITY_TAG` runs here: theOrg's `prometheus/scrape-stack/*.yml` (alert-relay, alertmanager,
loki, prometheus-trends, pushgateway, scrape-proxy, vector), the two optional pieces'
(`scrape-optional/blackbox-exporter.yml`: also blackbox-selftest; `docker-state-exporter.yml`) and
`base_config.py`'s `prometheus`. A job whose service is not expected here (a replica's, or a tokened
service never deployed) is left out. This is theOrg's deploy step "Verify this stack's own scrape
targets are up" (#327), which reads the jobs from its checkout; d06 has only the images, so an
upgrade checks `STACK_JOBS` against theOrg's `prometheus/` at the new sha. A job theOrg adds there
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
