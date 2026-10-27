# Home Assistant on d01

Home Assistant Container reads the Ecobee (house furnace and heat pump) and the Cielo Breez Max
(garage mini-split) and serves their state at `/api/prometheus` for theOrg's trends Prometheus.
asyla backlog `2026-10-26-home-automation-home-assistant-container-on-d01-deploy`.

- **URL:** `https://homeassistant.asyla.org` through internal-access (LAN only, no tunnel).
- **Image:** `ghcr.io/home-assistant/home-assistant`, pinned in `compose.yml`. Not privileged, no
  host network: the cloud integrations in use need neither.
- **Network:** `home_assistant_net`, subnet `172.31.240.0/24`, created by `up`; no published ports.
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
~/scripts/d01/apps/home-assistant/home-assistant.sh up       # install configuration.yaml, start
~/scripts/d01/apps/home-assistant/home-assistant.sh verify   # health, folder modes, proxy settings
~/scripts/d01/apps/home-assistant/home-assistant.sh down     # stop
~/scripts/d01/apps/home-assistant/home-assistant.sh logs     # follow logs
~/scripts/d01/apps/home-assistant/home-assistant.sh backup   # mirror to the NAS, without .storage
```

## First-time setup

Order per ASY-HST-2: push, `./update_scripts.sh` on d01, then:

1. `home-assistant.sh up`. The first start appends the http proxy settings
   (`http-first-start.yaml`); Home Assistant moves them into `.storage/http` and ignores http YAML
   from then on. The next `up` installs `configuration.yaml` without them.
2. Deploy internal-access for d01 with a `homeassistant.asyla.org` block and `home_assistant_net`,
   and set the split-DNS CNAME through the pihole pipeline.
3. Open `https://homeassistant.asyla.org`, create the owner account (the operator), and set
   automatic backups with encryption on. Store the backup encryption key in OpenBao.
4. `home-assistant.sh up` again, then `verify`.
5. Add integrations in the UI: Ecobee, then Cielo. The operator types each login; no session does.
6. Create a long-lived access token for the trends Prometheus (a dedicated user), store it in
   OpenBao, and hand theOrg the target `https://homeassistant.asyla.org/api/prometheus`.

## Restore

`restore` brings back everything but `.storage`. Home Assistant then starts as new: restore its
latest backup from `config/backups` in the onboarding screen with the key from OpenBao, or add the
integrations again.
