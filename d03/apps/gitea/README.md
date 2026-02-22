# Gitea on d03

Git server, internal only. Served by the internal-proxy at **gitea** or **gitea.asyla.org** (DNS alias to d03). No ports published; no internet access.

## Data

- **Data:** `/mnt/docker/Gitea/data` (repos, SQLite DB, config)
- **Backups:** `gitea.sh backup` → tgz under `/mnt/nas/data1/docker`

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

## Commands

Same pattern as other d03 apps: `up`, `down`, `logs`, `refresh`/`update`, `backup`.
