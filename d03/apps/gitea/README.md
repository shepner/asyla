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
