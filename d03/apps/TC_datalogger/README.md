# TC_datalogger on d03

Torn City API data logger (→ BigQuery). First application on d03; managed entirely from this asyla app layout. App source is pulled from [shepner/TC_datalogger](https://github.com/shepner/TC_datalogger).

## Layout on d03

- **Working files**: `/mnt/docker/TC_datalogger/` (iSCSI — avoids NFS DB locking)
  - `repo/` — git clone of the app (build context; not in backups)
  - `TC_faction_crimes/`, `TC_faction_members/`, `TC_items/`, `TC_user_events/`, `TC_faction_chains/`, `TC_dashboard/` — each with `config/` and `logs/`
- **Backups**: tgz files in `/mnt/nas/data1/docker/` (e.g. `TC_datalogger-20250203-120000.tgz`)

## One-time setup (on d03)

1. Ensure `/mnt/docker` is mounted (iSCSI; run `~/setup_manual.sh` if needed).
2. Run provision (creates dirs and clones app repo):
   ```bash
   ~/scripts/d03/apps/TC_datalogger/provision.sh
   ```
3. Add per-service credentials (see upstream [TC_datalogger README](https://github.com/shepner/TC_datalogger)):
   - From **workstation** (with TC_datalogger project locally): run `./d03/apps/TC_datalogger/copy_config_to_d03.sh [d03]` to copy `credentials.json` and `TC_API_config.json` from each service’s `config/` to d03. Set `TC_DATALOGGER_SRC` if the project is not at `../TornCity/TC_datalogger` relative to the asyla repo.
   - Or copy manually into `/mnt/docker/TC_datalogger/<service>/config/` on d03.
4. Start:
   ```bash
   ~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh up
   ```

## Commands (on d03)

All commands source `~/scripts/docker/common.env` (DOCKER_DL, DOCKER_D1).

| Command | Action |
|--------|--------|
| `tc_datalogger.sh backup` | Create tgz of working dirs (excl. repo) in `/mnt/nas/data1/docker/` |
| `tc_datalogger.sh update` | `git pull` in repo, rebuild images, `up -d` |
| `tc_datalogger.sh refresh` | Rebuild and `up -d` (no pull) |
| `tc_datalogger.sh rebuild` | `build --no-cache` and `up -d` |
| `tc_datalogger.sh up` | Build if needed and start |
| `tc_datalogger.sh down` | Stop and remove containers |
| `tc_datalogger.sh logs [service]` | Follow logs (use `--until=1h` in script if desired) |

Run from the app script path, e.g.:

```bash
~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh backup
~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh update
```

Optional: add a symlink for convenience:

```bash
ln -sf ~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh ~/tc_datalogger.sh
~/tc_datalogger.sh backup
```

## Restore from backup

1. Stop: `tc_datalogger.sh down`
2. Restore: `tar -xzf /mnt/nas/data1/docker/TC_datalogger-YYYYMMDD-HHMMSS.tgz -C /mnt/docker`
3. Re-run provision if repo is missing: `provision.sh`
4. Start: `tc_datalogger.sh up`
