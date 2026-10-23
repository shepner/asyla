# unifi-backup (d03)

Copies the UniFi Network autobackups of the consoles **MKE** (home, Cloud Key G2 Plus `unifiMgt`) and
**DAY** (the operator's parents' site) to the NAS, checks that each copy opens, and alerts through
host-maintenance when a copy is missed (asyla backlog item
`2026-10-23-network-unifi-controller-backups-to-nas`). Read-only toward UniFi: GET only.

- **How it reaches the files:** Ubiquiti's Site Manager connector,
  `https://api.ui.com/v1/connector/consoles/{id}/proxy/network/dl/autobackup/`: `autobackup_meta.json`
  (each file's name, time, version and size), then each `.unf` by name. The connector passes
  `/proxy/network/` only; UniFi OS paths answer 403 (2026-10-23). The Cloud Key's SSH is off and stays
  off. DAY's LAN collides with the home 192.168.1.0/24, so the connector is the one path to both.
- **What it copies:** the Network application's autobackups (Settings > Control Plane > Backups),
  monthly on both consoles: MKE 00:30 on the 1st America/Chicago (settings only, about 83 KB), DAY
  00:00 on the 1st America/New_York (180 days of statistics, 2-15 MB). The operator keeps that
  schedule (2026-10-23: "Its not like these configs change very often"). The weekly UniFi OS console
  backups stay on the Cloud Key: the connector cannot reach them.
- **Where:** `/mnt/nas/data1/docker/unifi-backup/<console>/autobackup_*.unf` (folder mode 700,
  files 600: a `.unf` holds WLAN passphrases and admin password hashes; its encryption is a fixed
  public key). Every file the console lists is copied once and never deleted here; nas01's daily
  ZFS snapshots of `data1/docker` (kept two weeks, replicated to the backup pool) are the history
  beyond that.
- **When:** `unifi_backup.py` every hour in the `unifi-backup` container (compose.yml). A file is
  fetched to `FILE.part`, checked, then renamed; a name already there is skipped.
- **The check (each copy, and `check`):** the size the console listed; AES-128-CBC decrypt with
  the key and IV every `.unf` uses (github.com/zhangyoufu/unifi-backup-decrypt `decrypt.sh`); the
  zip inside opens, every member's CRC holds, it has `version` and `db.gz`, and `db.gz`
  decompresses. That is the file Network > Settings > Control Plane > Backups > Restore takes.
- **Alerts:** `/mnt/docker/unifi-backup/status.json`, read by host-maintenance's monitor
  (`[[status]]` unifi-backup in its `config/maintenance.toml`; stale after 150 minutes is urgent).

  | Problem | Severity |
  | --- | --- |
  | The console's newest autobackup not on the NAS 24 h after it was made (`copy_grace_hours`) | urgent |
  | A console cannot be read or a file fetched | warn, urgent from the 3rd cycle in a row |
  | A copy fetched but its check fails (it is not kept) | warn |
  | The console's newest autobackup older than `max_age_days` (32: autobackup off or failing) | warn |
  | The console lists no autobackup | warn |
  | A staged test alert (`stage`) | urgent |

- **Key:** `UNIFI_SITE_MANAGER_API_KEY`, the asyla organization's Site Manager key, the one
  unifi-monitor uses. It is in no file: `build_host.py` resolves it from OpenBao on the workstation
  and sends it over SSH stdin (`start_env` in `d03/host.toml`), and `unifi-backup.sh up` refuses to
  start without it. It then sits in the container's environment. Through the connector it acts as
  the account owner; this app sends GET only.
- **Start or restart** (from the workstation; also after the key is rotated):

  ```
  cd ~/local/asyla && python3 core/tools/credentials.py exec UNIFI_SITE_MANAGER_API_KEY -- python3 projects/asyla-hosts/scripts/build_host.py d03 build --only apps --app unifi-backup --apply
  ```

  `down`, `logs`, `verify`, `status` and `check` need no key.
- **Check:** `unifi-backup.sh verify` (container running and healthy or starting, `status.json`
  under 130 minutes old); `unifi-backup.sh status`; `unifi-backup.sh check [FILE...]` (default:
  each console's newest copy opens).
- **Test the alert path:** `unifi-backup.sh stage [MINUTES] [NOTE]` adds one urgent problem from the
  next cycle until it expires (default 150 minutes); `unstage` ends it.
- **Restore a console:** download the copy you want from the NAS, then in that console's Network
  application, Settings > Control Plane > Backups > Restore (upload). A new Cloud Key is set up in
  UniFi OS first, then its Network application takes the file.
- **backup / restore** (host-maintenance, `update_all.sh`): nothing to do; the copies are already on
  the NAS and `state.json` rebuilds in one cycle.
