# Gitea on d04

Copied from `d03/apps/gitea/` for the move to d04, theOrg's forge host (asyla hub
decisions/host-layout.md). Differences from d03's copy: `verify` fails on a local `:3000`
`/api/healthz` failure (until the cutover the public URL reaches d03's Gitea), and the comments
name d04.

Git server, internal only. Served by the internal-proxy at **gitea** or **gitea.asyla.org** (DNS alias to d03 until the cutover, then to d04). No ports published; no internet access.

## Data

- **Data:** `/mnt/docker/Gitea/data` (repos, SQLite DB, config)
- **Backups:** `gitea.sh backup` → rsync mirror at `/mnt/nas/data1/docker/Gitea/mirror` (~33 GB, ~43k files); history is nas01's daily ZFS snapshots. See [../README.md](../README.md).

## Backup

Not in the nightly until the cutover (operator, 2026-10-15): host-maintenance is to list gitea on d04
as watch-only, and the cutover moves the nightly (03:00 CDT, `TASK=backup`) from d03 to d04 in one change. Gitea's
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

`gitea.sh backup` refuses (`[ERROR]`, exit 1) unless `gitea.asyla.org` resolves to one of this
host's addresses (`getent ahostsv4`, `hostname -I`): every host's copy backs up to the same mirror,
so only the host that serves Gitea may write it. `restore`, `verify` and the others do not check.

Not backed up: `data/ssh/` (host keys for the built-in sshd, root-only; nothing can reach that sshd and
the container regenerates the keys) and `gitea.db-journal`.

## Restore

With the app down (`gitea.sh down`):

```bash
sudo rsync -aH --delete --exclude=/.backup-status --exclude=/data/ssh/ /mnt/nas/data1/docker/Gitea/mirror/ /mnt/docker/Gitea/
~/scripts/d04/apps/gitea/gitea.sh up
docker exec -u git gitea gitea admin regenerate hooks   # Gitea docs: needed or pushes can fail
```

Existing `data/ssh/` keys are kept; on a fresh disk the container creates new ones (only SSH clients would notice).
For an earlier day, copy from nas01's ZFS snapshot instead (see [../README.md](../README.md)).

## Registry retention

Three package cleanup rules, turned on 2026-11-04 with the operator's approval, one per organisation:

| Rule | Owner | Enabled | Type | Keep the most recent | Keep versions matching | Remove versions older than | Remove versions matching | Match full name |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | theOrg | yes | container | 0 | empty | 7 days | empty | off |
| 2 | asyla | yes | container | 0 | empty | 7 days | empty | off |
| 3 | personal | yes | container | 0 | empty | 7 days | empty | off |

- **Set in the web UI only:** Gitea 1.27.3 has no REST API for cleanup rules (org Settings →
  Packages → Cleanup rules, `/org/<owner>/settings/packages/rules`). Don't open theOrg's Preview
  page: on 2026-11-04 it held the database for 207 s and Gitea's health check failed meanwhile.
- **Always kept:** each package's `latest`, and a `sha256:` digest version while a kept version
  still references it. Everything else older than 7 days is deleted with its files
  ([cleanup.go](https://github.com/go-gitea/gitea/blob/v1.27.3/services/packages/cleanup/cleanup.go),
  [container/cleanup.go](https://github.com/go-gitea/gitea/blob/v1.27.3/services/packages/container/cleanup.go)).
- **When:** Gitea's `cleanup_packages` job, once a night at 01:30 America/Chicago, and never at
  start (operator, 2026-11-06). app.ini `[cron.cleanup_packages]` sets `RUN_AT_START = false` and
  `SCHEDULE = 30 1 * * *`. Gitea's defaults are `@midnight` and at every start
  ([tasks_basic.go](https://github.com/go-gitea/gitea/blob/146cc3eec57174711eac0e0a0c7b38670c6e3922/services/cron/tasks_basic.go#L145-L157);
  Gitea reads each job's keys from its `cron.<name>` section,
  [setting/cron.go](https://github.com/go-gitea/gitea/blob/146cc3eec57174711eac0e0a0c7b38670c6e3922/modules/setting/cron.go#L13-L14),
  and runs a job at start only when `RUN_AT_START` is on,
  [cron.go](https://github.com/go-gitea/gitea/blob/146cc3eec57174711eac0e0a0c7b38670c6e3922/services/cron/cron.go#L41-L45)).
  A schedule of fewer than 6 fields is a standard 5-field crontab, minute first
  ([tasks.go](https://github.com/go-gitea/gitea/blob/146cc3eec57174711eac0e0a0c7b38670c6e3922/services/cron/tasks.go#L227-L244)),
  in Gitea's local time
  ([cron.go](https://github.com/go-gitea/gitea/blob/146cc3eec57174711eac0e0a0c7b38670c6e3922/services/cron/cron.go#L24)):
  the container's `/etc/localtime` is d04's, America/Chicago. Links are to v1.27.3; the keys are
  also in the [config cheat sheet](https://gitea.com/gitea/docs/src/commit/0ddb9a20710a0e3f040f87f35054b76da897db1b/versioned_docs/version-1.27/administration/config-cheat-sheet.md#L1102-L1108).
  The same job frees blobs nothing references.
- **Why that time:** at Gitea's defaults the job ran two to four times a night (midnight, and
  at each start after the 03:35 backup), and each run held the sqlite database for 6 to 15
  minutes. Meanwhile issue creation, runner job fetches and scheduled Actions failed with
  `database is locked`. Details: asyla hub backlog
  `2026-11-06-hosts-gitea-nightly-package-cleanup-locks-the-forge`.
- **Set by `gitea.sh cron-config`:** it sets the two keys and changes no other line of app.ini,
  after a backup `app.ini.bak-<UTC time>Z` beside it. It prints only those keys, never the rest of
  app.ini (Gitea's secrets), and does nothing when they are already set. Gitea reads app.ini at
  start, so the change applies at Gitea's next start, the nightly backup's stop and start. It needs
  no extra restart, and `cron-config` never restarts Gitea. `gitea.sh verify` prints the two keys,
  warns when they differ or `ENABLED` is off, and notes when app.ini changed after Gitea started.
- **Revisit before mid-March:** theOrg's deploy-all runs at 06:00 UTC: 00:00 CST, but 01:00 CDT,
  until about 02:20. From mid-March (CDT), a 01:30 run would overlap it, so choose the time again
  before then.
- **Why:** the registry grew about 2 GB a day from per-commit images (theOrg pushes every image
  tagged with the commit on each push to main), filling d04's disk and slowing the nightly backup.
  Hosts follow `latest` and are redeployed weekly, so none runs a version the rules remove.
- `gitea.sh verify` prints the rules (read-only) and warns when one is missing or differs from the
  table above.

History and the decision: asyla hub backlog `2026-11-03-hosts-gitea-registry-retention-for-theorg-images`.

## Break-glass admin access (no identity provider)

The way back in as a site admin when sign-in through the identity provider (or any password) does
not work. Everything here runs on d04 through `docker exec`, so it needs only `ssh d04` as
`docker`; it never touches an identity provider. Hub runbook: `runbooks/gitea-break-glass.md` in
the asyla hub.

**Tested:** every command below on a throwaway `docker.gitea.com/gitea:1.27.3` by theOrg,
2026-11-08T02:52Z (theOrg people's-access plan piece 11; ms-procedural situation `70nkolo1`).
Live on d04, read-only, 2026-11-20T14:47Z: `gitea admin user list --admin` listed one admin,
`shepner` (ID 1, active); the only `GITEA__service` setting was `DISABLE_REGISTRATION=true`; Gitea
1.27.3. Nothing was changed. The compose pins the floating tag `gitea:1`: after a minor upgrade,
re-check the flags with `--help` before relying on them.

Rules that apply to every command:

- Run the CLI as the git user: `docker exec -u git gitea gitea admin ...`. As root it exits 1
  ("not supposed to be run as root").
- Gitea 1.27.3 takes a password only in argv (no stdin option), so it lands in the shell history
  and process list. Use a temporary one with `--must-change-password`, or `--random-password`.
- While must-change-password is set on a user, every API call as that user returns 403, tokens
  included, until they sign in on the web and change it.

**1. Who are the admins** (read-only):

```bash
ssh d04 'docker exec -u git gitea gitea admin user list --admin'
```

**2. Token path, no password** (works whether or not the password form is on):

```bash
ssh d04 'docker exec -u git gitea gitea admin user generate-access-token -u shepner -t break-glass-$(date -u +%Y%m%d) --scopes all --raw'
```

It prints an admin token once (`GET /api/v1/admin/users` → 200 with it). Keep it out of files and
logs; use it for the repair, then revoke it with itself:
`curl -fsS -X DELETE -H "Authorization: token <token>" https://gitea.asyla.org/api/v1/token/break-glass-<date>`
(204; the token then gets 401). The CLI has no revoke; the web UI (Settings → Applications) also works.

**3. Web sign-in, while the password form is on** (today's d04 config):

```bash
# reset an existing admin's password; they must change it at first sign-in
ssh d04 'docker exec -u git gitea gitea admin user change-password -u shepner -p <temporary> --must-change-password'
# or make a second admin; the password is printed once
ssh d04 'docker exec -u git gitea gitea admin user create --username <name> --email <email> --admin --random-password --random-password-length 24 --must-change-password'
```

**4. Web sign-in, once the password form is off.** When SSO lands, theOrg's plan sets
`GITEA__service__ENABLE_PASSWORD_SIGNIN_FORM=false`. From then on a CLI password reset no longer
restores web sign-in (the correct password gets 403). The CLI token (2) and machine accounts'
tokens keep working, so repairs through the API still do. The only way back to the web without the
identity provider:

1. In `compose.yml`, set `GITEA__service__ENABLE_PASSWORD_SIGNIN_FORM=true` (or remove the line),
   and recreate the container: `~/scripts/d04/apps/gitea/gitea.sh up`. This is a production change
   on the forge (operator's yes for the exact action).
2. Reset the password as in (3) and sign in.
3. Once the identity provider is back, set the line to `false` again and recreate the container.

Open sign-up stays off throughout: the compose sets `GITEA__service__DISABLE_REGISTRATION=true`
(the image default is open sign-up).

## Usage

```bash
# First run (ensure proxy networks exist; start Gitea before internal-proxy if proxy not yet up)
~/scripts/d04/apps/gitea/gitea.sh up

# Later: pull new image and start
~/scripts/d04/apps/gitea/gitea.sh refresh

# Backup
~/scripts/d04/apps/gitea/gitea.sh backup
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

Same pattern as the other apps: `up`, `down`, `logs`, `refresh`/`update`, `backup`.
