# observability (d06)

theOrg's observability stack: Loki and its gateway, Prometheus, the trends Prometheus,
Alertmanager, alert-relay, the pushgateway, Vector, docker-state-exporter and blackbox-exporter.
asyla deploys it here from theOrg observability `DEPLOY.md` at main
`2144f83c3ec978663d3cb544e743ae8006471a0a`, using theOrg's published images of that sha.

- `compose.yml`: theOrg's `docker-compose.yml` with `compose.docker-socket.yml` and
  `compose.blackbox.yml` folded in (the Docker-socket and blackbox pieces are on). `MONITOR_THEORG`
  is off: credential-probe, the Ollama log and the other stacks' jobs and rules are theOrg's, not
  here. Project, container, volume and network names are theOrg's. No build sections.
- `observability.sh`: `up`, `down`, `restart`, `verify`, `update`, `pull`, `images`, `logs`,
  `status`. It pins the tag, sets the settings, creates the data directories and keeps the start
  order. A replica (a host with `[replica] of = "d06"`) runs only the services with nothing to reach
  off the host.
- `docker-credential-observability-env`: the credential helper `observability.sh` points Docker at
  for the pulls (below).
- `trends-scrape-off.yml`: an empty `scrape_configs`, bind-mounted over two baked-in scrape files
  of the trends Prometheus (the Home Assistant job and emporia-collector's own).
- Data: `/mnt/docker/Observability/{alertmanager-data,loki-data,prometheus-data,prometheus-trends-data}`
  on d06's local data disk, bound into the named volumes; never NFS (theOrg decision
  asyla-network-monitoring section 8). Vector's disk buffer is a plain named volume.
- Caps: DEPLOY.md's defaults, none overridden here. Loki keeps 744h, ingests 0.05 MB/s with a
  burst of 16 MB; Prometheus keeps 15d or 8GB; the trends Prometheus keeps 24GB (size only, sized
  for the 64 GiB data disk). `compose.yml` takes `PROMETHEUS_RETENTION_TIME`,
  `PROMETHEUS_RETENTION_SIZE` and `TRENDS_RETENTION_SIZE` from the environment if one is ever set.
- Ports: the Loki gateway on `3100`, every address (callers off this host push through it); every
  other port on `127.0.0.1` only: Prometheus `9090`, trends `9107` (container `9090`),
  Alertmanager `9093`, pushgateway `9091`, alert-relay `9111`, Vector `9598`,
  docker-state-exporter `9099`. Loki, alert-relay's health port and blackbox-exporter are not
  published.
- Names (`caddy-internal-d06`, LAN only): `prometheus.asyla.org`, `alertmanager.asyla.org` and
  `prometheus-trends.asyla.org`. They are the external URLs Prometheus and Alertmanager put in
  links (`PROMETHEUS_EXTERNAL_URL`, `ALERTMANAGER_EXTERNAL_URL` in `observability.sh`). The proxy
  entries belong to the asyla `internal-access` repo (`hosts/d06`), a separate change: none is
  there yet (checked in `projects/internal-access`).

## Secrets

No secret is in any file or volume, here or on the host, on disk or in memory (core `secrets.md`
SEC-5 and SEC-7; the operator, 2026-11-03: "secrets are to live in the vault" and "then they need
to be fixed", meaning the stack is fixed to read them from OpenBao itself). Nothing in this
directory writes a value anywhere. Only one value may reach a process, as a named environment
variable that the workstation resolves from OpenBao at use and sends over SSH stdin (build_host.py,
`pull_token_env`):

- `OBSERVABILITY_REGISTRY_PULL_TOKEN`: the `theorg-registry` read:package token for the image
  pulls (`pull_token_env = "THEORG_REGISTRY_PULL_TOKEN"` in `d06/host.toml`). The credential helper
  answers Docker from it under a throwaway `DOCKER_CONFIG`; nothing is stored.

No secret goes in any container's environment: Docker keeps a container's environment in the
container's config on the host (`config.v2.json`; `docker inspect` shows it): inference from
Docker's behaviour, not checked on d06. So alert-relay gets no forge token. It files nothing until
theOrg's `secrets-alert-relay` change: the relay then logs in to OpenBao itself through a
single-use wrapped token minted from the `observability-d06` token role, so no secret ever sits in
its environment. `relay.py` serves without a token.

## Off, and what turns each on

Each piece below is off here and nowhere else, because it needs a value that would otherwise sit in
a file or a volume. Each turns on when theOrg's stack reads that value from OpenBao itself (the
branch named is theOrg's, from the last sections of the deploy notes); asyla then bumps the pinned
tag. `compose.yml`'s header says how each is off.

- Email receiver: Alertmanager gets no mail login, so its entrypoint leaves the email piece off.
  Every alert still goes to alert-relay. On: `secrets-alert-relay`.
- Watchdog ping and delivery ping: Alertmanager gets no ping address (its watchdog piece is off)
  and alert-relay gets none (its delivery ping is off). On: `secrets-alert-relay`, where
  alert-relay reads OpenBao in-process.
- Home Assistant trends: `trends-scrape-off.yml` replaces the job's scrape file in the trends
  Prometheus. On: `secrets-scrape-proxy`.
- emporia-collector and the Loki gateway accounts: emporia-collector is not a service here (its
  scrape file is replaced the same way), and the gateway has no verifier files, so it refuses every
  push and query (401 or 403) and answers `/ready` alone; alert-relay's log lines to Loki are off with
  it. On: `secrets-in-process-emporia-loki`.
- Loki TLS: no leaf, so Loki serves HTTP inside `observability-net` and the gateway serves HTTP.
  On: `secrets-loki-tls` (step-ca, the key held in memory by the process).

## Upgrade

Change `OBSERVABILITY_TAG` in `observability.sh` to a theOrg `main` sha whose images are published,
commit, then `observability.sh update up verify`. `verify` checks the services are healthy,
Prometheus is healthy with one Alertmanager, `docker_container_running` on `9099`, the trends
retention is a size, the gateway's `/ready` over HTTP and a 401 or 403 on an unauthenticated push, and the
three blackbox self-probes (it waits up to `VERIFY_WAIT_S`).

## Known limits

- No backup yet. A lost `/mnt/docker/Observability` is lost; the app has no `restore` switch
  (`restore = false` in `host.toml`).
- The trends Prometheus starts empty on d06. theOrg re-runs its `emporia-history` to fill it.
- The Mini's emporia-collector keeps running until d06's trends writes, then theOrg turns it off.
- alert-relay files nothing until theOrg's `secrets-alert-relay` change (it logs in to OpenBao
  itself; see Secrets) and the `asyla/alerts` repo exist.
- From d06 (10.0.0.65) the trends jobs `asyla-d03-node`, `asyla-d07-node` and `asyla-switch-snmp`
  read `up=0`. The ports they scrape admit only 10.0.0.150 (the Mini): `d03/host.toml:27`,
  `d07/host.toml:33` and `d07/host.toml:47`. A follow-up widens those allow lists to the LAN
  subnet; d03 and d07 are not changed here.
- d06's `update_all.sh` reports this app as FAIL. It runs `backup`, which this app does not have,
  and `update`, which needs the pull token from the workstation. This matches ticketing's `update`.
- With the gateway's accounts off, no caller off this host can push logs or query Loki; only this
  stack's own Vector reaches Loki, inside `observability-net`.
