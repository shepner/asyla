# Home Assistant on d01

Home Assistant Container reads the Ecobee (house furnace and heat pump) and the Cielo Breez Max
(garage mini-split) and serves their state at `/api/prometheus` for theOrg's trends Prometheus.
asyla backlog `2026-10-26-home-automation-home-assistant-container-on-d01-deploy`.

- **URL:** `https://homeassistant.asyla.org` through internal-access (LAN only).
- **Image:** `ghcr.io/home-assistant/home-assistant`, pinned in `compose.yml`. Not privileged, no
  host network: the cloud integrations in use need neither.
- **Network:** `home_assistant_net`, subnet `172.31.240.0/24`, created by `up`; no fixed address,
  no published ports.
- **Storage:** `${DOCKER_DL}/home-assistant/config` → `/config`. `configuration.yaml`, `packages/`
  and `asyla/` come from this folder on every `up`; edit them here.

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
~/scripts/d01/apps/home-assistant/home-assistant.sh up       # install configuration.yaml, packages/, asyla/ and custom_components, trust the proxy, start
~/scripts/d01/apps/home-assistant/home-assistant.sh verify   # health, folder modes, proxy trusted, packages/, asyla/ and custom_components match
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
5. Add integrations in the UI: Ecobee, then Cielo, then Watts Home (below). The operator types each
   login; no session does.
6. Create a long-lived access token for the trends Prometheus (a dedicated user), store it in
   OpenBao, and hand theOrg the target `https://homeassistant.asyla.org/api/prometheus`.

## Watts Home

The Watts tekmar 562 boiler thermostat has no core integration. `custom_components/watts_home/` is
[ha-watts-home](https://github.com/bhamiltoncx/ha-watts-home) (Apache-2.0, upstream `LICENSE` kept),
vendored at one reviewed commit; no HACS. `PIN.txt` records the commit, version and archive sha256.

- **One local change:** `manifest.json` requires `curl_cffi==0.16.3` instead of upstream's
  `curl_cffi>=0.7.0`: 0.17.0 needs `cffi>=2.1.1` and Home Assistant 2026.10.4 constrains
  `cffi==2.0.0`. Home Assistant installs that one PyPI package into the container when it loads the
  integration, and again after each container recreate.
- **Install:** `up` mirrors each folder in `custom_components/` into `config/custom_components/`
  (folders 700, files 600, files no longer shipped removed, `__pycache__` left alone); `verify`
  checks the copy matches this folder. Home Assistant loads custom integrations only at start; `up`
  copies first and then stops and starts Home Assistant to set the proxy trust, so `up` is the
  restart it needs.
- **Add it:** Settings → Devices & services → Add integration → "Watts Home (Tekmar)". The operator types the
  Watts Home app login. It stays in Home Assistant storage like the Ecobee login (asyla
  `decisions/home-assistant-integration-logins.md`).
- **What it gives:** controls, not only readings: a climate entity per thermostat (mode, setpoints;
  emergency heat shows as heat), an away switch per location, numbers and sensors. It polls the
  Watts cloud.

### Bump the pin

1. Read the new commit's `custom_components/watts_home` in full. It must contact only
   `https://login.watts.io` and `https://home.watts.com/api`, with no subprocess, eval, file writes
   or telemetry.
2. Recheck `curl_cffi` against Home Assistant's `cffi` constraint for the image in `compose.yml`
   (`homeassistant/package_constraints.txt`), and pick the newest release that fits.
3. On WS01: `python3 -I scripts/vendor_ha_watts_home.py FULL_SHA --curl-cffi VERSION`. It refuses a
   short SHA, an archive that is not that commit, and any other upstream requirement.
4. Review `git diff`, commit, push; then `update_scripts.sh`, `up` and `verify` on d01.

## HVAC cold-spell report

asyla backlog `2026-10-27-home-automation-hvac-schedule-optimiser-lowest-energy-heating-and-cooling-sc`:
the HVAC run report is re-run when the weather turns cold, triggered by Home Assistant's own weather
data (operator, 2026-10-28). Read-only: nothing here changes a thermostat.

- `packages/hvac.yaml` (loaded through `homeassistant: packages:` in `configuration.yaml`):
  - `sensor.mke_temperature_24_h_minimum`: a `statistics` sensor, the lowest
    `sensor.mke_temperature` (Ambient Weather station, °C) over the last 24 h.
  - `shell_command.hvac_cycle_report`: `python3 /config/asyla/report_hvac_cycles.py --days 7`.
  - `input_datetime.hvac_cold_spell_report_last_success`: when the last successful report ran
    (local date and time). It has no `initial`, so Home Assistant restores it at every start. With
    nothing to restore it starts as today 00:00:00, which the automation reads as never set.
  - Automation "HVAC cold-spell report": daily at 09:00, when that minimum is below 0 °C (the gate
    assumes `sensor.mke_temperature` is in °C) and the last successful report is 7 or more days
    old by local date, or never happened (unknown, unavailable or the 00:00:00 start value). It
    runs the report and, only when the script exits 0, sets the `input_datetime` to now. A failed
    run (Prometheus down, a timeout) leaves it alone, so the report is tried again at 09:00 the
    next day. Either way it puts the output, or the failure, in a persistent notification, then
    mails it to `notify.hvac_report`.
- `asyla/report_hvac_cycles.py`: the report (standard library only). This is its only copy; the
  asyla hub's `tools/report_hvac_cycles.py` runs this file from the hub's clone of this repo. It
  reads theOrg's trends Prometheus at `http://10.0.0.150:9107` with GET only (reached from this
  container: HTTP 200, 2026-10-29T00:00Z). It must finish within `shell_command`'s 60 s: each
  request waits at most 10 s and the run at most 45 s, then it exits 2 with an `[ERROR]` line,
  which the mail carries.
- Test on WS01: `python3 scripts/tests/test_home_assistant_hvac.py` (with the image in
  `compose.yml` pulled, it also runs Home Assistant's `check_config` and the templates in it).

**Mail (operator, once).** The SMTP integration is set up in the UI (Home Assistant 2026.10 has a
config flow for it), so its login is an integration login under asyla
`decisions/home-assistant-integration-logins.md`: the operator types it, and it is the narrowest
one available, a Google app password made for Home Assistant alone (revocable on its own; not
host-maintenance's).

1. Settings → Devices & services → Add integration → SMTP: server `smtp.gmail.com`, port 587,
   STARTTLS, the sending address and its app password.
2. On the SMTP entry, add a recipient (the operator's address). Open its notify entity and set the
   entity ID to `notify.hvac_report`.
3. Settings → Automations → "HVAC cold-spell report" → Run actions: sends one report now (this
   skips the conditions; when the report succeeds it sets
   `input_datetime.hvac_cold_spell_report_last_success`, so the next cold-spell report is 7 days
   later).

## Restore

`restore` brings back everything but `.storage`. Then `up`: Home Assistant starts as new and `up`
sets the proxy trust on that first start. Open `https://homeassistant.asyla.org` and, in the
onboarding screen, restore the latest backup from `config/backups` with the key from OpenBao.
