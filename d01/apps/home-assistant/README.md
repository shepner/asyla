# Home Assistant on d01

Home Assistant Container reads the Ecobee (house furnace and heat pump) and the Cielo Breez Max
(garage mini-split) and serves their state at `/api/prometheus` for theOrg's trends Prometheus.
asyla backlog `2026-10-26-home-automation-home-assistant-container-on-d01-deploy`.

- **URL:** `https://homeassistant.asyla.org` through internal-access (LAN only).
- **Image:** `ghcr.io/home-assistant/home-assistant`, pinned in `compose.yml`. Not privileged, no
  host network: the cloud integrations in use need neither.
- **Network:** `home_assistant_net`, subnet `172.31.240.0/24`, created by `up`; no fixed address,
  no published ports.
- **Storage:** `${DOCKER_DL}/home-assistant/config` → `/config`. `configuration.yaml` comes from
  this folder on every `up`; edit it here.

## The config folder is a secret

UI-added integrations keep their logins and tokens in `config/.storage/core.config_entries`,
written mode 0644 by Home Assistant. This is an operator-approved exception to the secrets rule,
with conditions: asyla `decisions/home-assistant-integration-logins.md`.

- `up` keeps `${DOCKER_DL}/home-assistant` and `config/` at mode 700; `verify` checks it.
- Never list, print or copy files from `config/.storage`, and never paste them into a session.
- The backup mirror leaves out `.storage/`, the YAML secrets file, the recorder database and logs.
  Home Assistant's own backups (encrypted by default, in `config/backups`) are mirrored and carry
  `.storage`. Their encryption key is in OpenBao, not on disk.

## Commands

```bash
~/scripts/d01/apps/home-assistant/home-assistant.sh up       # install configuration.yaml, trust the proxy, start
~/scripts/d01/apps/home-assistant/home-assistant.sh verify   # health, folder modes, proxy trusted
~/scripts/d01/apps/home-assistant/home-assistant.sh down     # stop
~/scripts/d01/apps/home-assistant/home-assistant.sh logs     # follow logs
~/scripts/d01/apps/home-assistant/home-assistant.sh backup   # mirror to the NAS, without .storage
```

## First-time setup

Order per ASY-HST-2: push, `./update_scripts.sh` on d01, then:

1. `home-assistant.sh up`. It sets the proxy trust itself (use X-Forwarded-For, trusted proxy
   `172.31.240.0/24`). Home Assistant 2026.10 takes an `http:` YAML block or a UI change only as a
   pending trial that reverts after 5 minutes unless an admin promotes it (core
   `homeassistant/components/http/config.py`, `AUTO_REVERT_DELAY`), and a first start has no admin.
   `up` instead writes the stable half of `config/.storage/http` with Home Assistant stopped, which
   needs no admin: `http-trust-proxy.py`, run in the pinned image. On a first start `up` waits for
   Home Assistant to create that file, sets the trust and starts it again. It is the one `.storage`
   file the scripts touch, and it holds no secrets (port, CORS, proxy and ban settings). Do not put
   an `http:` block in `configuration.yaml`.
2. Deploy internal-access for d01 with a `homeassistant.asyla.org` block and `home_assistant_net`,
   and set the split-DNS CNAME through the pihole pipeline.
3. Open `https://homeassistant.asyla.org` and create the owner account (the operator). Turn on
   automatic backups with encryption, and store the backup encryption key in OpenBao.
4. `home-assistant.sh verify` (health, modes, and a request through the proxy that is not 400).
5. Add integrations in the UI: Ecobee, then Cielo. The operator types each login; no session does.
6. Create a long-lived access token for the trends Prometheus (a dedicated user), store it in
   OpenBao, and hand theOrg the target `https://homeassistant.asyla.org/api/prometheus`.

## Restore

`restore` brings back everything but `.storage`. Then `up`: Home Assistant starts as new and `up`
sets the proxy trust on that first start. Open `https://homeassistant.asyla.org` and, in the
onboarding screen, restore the latest backup from `config/backups` with the key from OpenBao.
