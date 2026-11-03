# observability (d06)

theOrg's observability stack: Loki, Prometheus, the trends Prometheus, Alertmanager,
alert-relay, emporia-collector, scrape-proxy, the pushgateway, Vector, docker-state-exporter and
blackbox-exporter, without theOrg's loki-gateway (On, off, below). asyla deploys it here from
theOrg observability `DEPLOY.md` at main `64a2bf35c19275dadc577cdb37f9434064cf0842` (#311, design
4), using theOrg's published images of that sha (each of the ten theOrg images this stack names
answered HTTP 200 to a registry manifest read, 2026-11-03).

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

The recovery is the deploy above (`deploy_role.py`), run by hand. Recovering on its own (a token
the services can use again after a restart) is open with theOrg: it is their token convention.

## On, off, and what turns each on

On: critical alerts by email (Alertmanager's email piece posts them to alert-relay, which sends
them to `ALERT_EMAIL_TO` through `smtp.gmail.com:587` with the SMTP login), the trends Home
Assistant job (through scrape-proxy), emporia-collector, and Vector's container-log pipeline
(`VECTOR_DOCKER_LOGS`, with the Docker socket mounted as theOrg's `compose.docker-socket.yml` does):
this stack's own container logs to Loki over plain HTTP inside `observability-net`, and their
`CHRONICLE_EPISODE` lines to memory-system's Vector on the Mini. At 7572365 it was off, because its
Loki sink named `/etc/loki-ca/root_ca.crt`; at 64a2bf3 no Vector file names a CA or has a tls block.

Off here and nowhere else:

- Alert issues on the forge: the forge token record is not stored. On: store
  `observability-alert-relay-gitea-token`, then deploy (the relay reads its records at start).
- Delivery ping: same, record `observability-delivery-ping-url`.
- Watchdog ping: record `observability-watchdog-ping-url`, and `ALERT_WATCHDOG_PING="on"` in
  `observability.sh` (one line; alert-relay already names the record). Then deploy.
- The Loki gateway, so any log push or query from off this host (theOrg lead's option A for d06,
  2026-11-03). theOrg's 64a2bf3 gateway reads its accounts from OpenBao with its own wrapped token
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
the trends retention is a size, the three blackbox self-probes, and (not on a replica) that
Vector's container logs reach Loki: lines labelled `forwarder="vector-observability"` in the last
10 minutes, read from inside the network (`vector-1`'s wget to `loki:3100`). Each waits up to
`VERIFY_WAIT_S`. For each tokened service whose container exists, it also checks that the service
holds its secrets, waiting once more up to `VERIFY_WAIT_S` for the first scrape: the trends
Prometheus (`9107`) reads `up{job="asyla-home-assistant"}` 1 (scrape-proxy) and `up{job="emporia"}`
1 (emporia-collector), the job names of theOrg `trends/scrape/asyla-home-assistant.yml` and
`trends/scrape/emporia.yml`; alert-relay's own metrics (`9111`) read
`alert_relay_secret_present{secret="smtp_username"}` and `{secret="smtp_password"}` 1 (theOrg
`alert-relay/relay.py`).

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
