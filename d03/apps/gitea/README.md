# Gitea on d03

Git server, internal only. Served by the internal-proxy at **gitea** or **gitea.asyla.org** (DNS alias to d03). No ports published; no internet access.

## Data

- **Data:** `/mnt/docker/Gitea/data` (repos, SQLite DB, config)
- **Backups:** `gitea.sh backup` → rsync mirror at `/mnt/nas/data1/docker/Gitea/mirror` (~33 GB, ~43k files); history is nas01's daily ZFS snapshots. See [../README.md](../README.md).

## Backup

Nightly at 03:00 CDT from host-maintenance (`TASK=backup HOSTS=d03`). Gitea's
[backup docs](https://docs.gitea.com/administration/backup-and-restore) say to stop it for a
consistent copy, so `gitea.sh backup` makes two passes into the mirror:

1. rsync while Gitea runs (the slow part; only what changed since last night).
2. Wait until no Gitea Actions job is running (up to `BACKUP_QUIET_WAIT_MIN`, 60), stop Gitea, rsync
   again (seconds), start it. The script logs how long Gitea was down. A trap restarts Gitea if the
   script is interrupted; if Gitea still stays down, the host-maintenance monitor alerts after 30 min.
3. `PRAGMA integrity_check` on the backed-up `gitea.db`; the backup fails if it isn't `ok`.

If Actions jobs are still running after the wait, Gitea is left up: the DB comes from an online
`sqlite3 .backup` snapshot (still consistent), the repos were copied live, and the backup exits 3 so
the digest shows it.

03:00 is after theOrg's `deploy-all` (Gitea Actions, cron 06:00 UTC, runs until ~02:20 CDT) and after
the 02:30 `scripts` task, which rewrites this script in place and must not run while Gitea is stopped.

Not backed up: `data/ssh/` (host keys for the built-in sshd, root-only; nothing can reach that sshd and
the container regenerates the keys) and `gitea.db-journal`.

## Restore

With the app down (`gitea.sh down`):

```bash
sudo rsync -aH --delete --exclude=/.backup-status --exclude=/data/ssh/ /mnt/nas/data1/docker/Gitea/mirror/ /mnt/docker/Gitea/
~/scripts/d03/apps/gitea/gitea.sh up
docker exec -u git gitea gitea admin regenerate hooks   # Gitea docs: needed or pushes can fail
```

Existing `data/ssh/` keys are kept; on a fresh disk the container creates new ones (only SSH clients would notice).
For an earlier day, copy from nas01's ZFS snapshot instead (see [../README.md](../README.md)).

## Usage

```bash
# First run (ensure proxy networks exist; start Gitea before internal-proxy if proxy not yet up)
~/scripts/d03/apps/gitea/gitea.sh up

# Later: pull new image and start
~/scripts/d03/apps/gitea/gitea.sh refresh

# Backup
~/scripts/d03/apps/gitea/gitea.sh backup
```

## First-time setup

1. Start Gitea, then internal-proxy (see [../README.md](../README.md)).
2. Open https://gitea.asyla.org/ (or https://gitea/ if your DNS uses that).
3. Complete the web installer (SQLite, default paths). ROOT_URL is already set to `https://gitea.asyla.org/`.

## Automation: adding remotes for local repos

To create Gitea repos and add remotes for many local projects (e.g. under `personal/projects`) without using the web UI:

1. Create an API token: https://gitea.asyla.org/user/settings/applications — create a token with repo scope.
2. Make the token available (one of): `export GITEA_TOKEN=your_token`, or put it in `~/.config/gitea/token` (chmod 600), or set `GITEA_TOKEN_FILE`.
3. Run the helper from a machine that can reach gitea.asyla.org (e.g. on same network or VPN):

   ```bash
   python3 .cursor/helpers/add_gitea_remotes.py /path/to/personal/projects
   ```

   The script finds all project dirs that have a git repo but no remote, creates the repo on Gitea (if it doesn't exist), adds `origin`, and pushes the default branch.

## Commands

Same pattern as other d03 apps: `up`, `down`, `logs`, `refresh`/`update`, `backup`.
