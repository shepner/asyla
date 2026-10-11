# ms-chronicle-backup (d03)

Nightly off-host copy of **ms-chronicle**'s backup: theOrg's episodic memory, which runs on the Mac
Mini. The Mini takes a restore-verified snapshot daily, onto the same disk as the archive; d03 pulls
the newest one over HTTPS into the NAS mirror, so the record survives the loss of that disk.
Operator, 2026-10-10: "a nightly d03 pull of the verified backup into
/mnt/nas/data1/docker/ms-chronicle/mirror, same mechanism and backup-only token class as
d03/apps/ms-procedural-backup, writing only inside that directory."

Written against theOrg memory-system `ms-chronicle-mcp/README.md`, section "Off-host copy: the pull
contract" (origin/main `705a1d8`). `verify-pull.py` is that section's check, copied without change:
replace it from there when the contract changes, do not edit it here.

- **When:** host-maintenance's `backup d03` schedule runs `ms-chronicle-backup.sh backup` with every
  other d03 app, once `config/maintenance.toml` lists `ms-chronicle-backup`. `update_all.sh` and
  `docker/backup_all.sh` also run every app's `backup` when a person starts them.
- **What:** `GET https://ms-chronicle-backup.asyla.org/api/v1/backup` (the tarball) and
  `/api/v1/backup/manifest?snapshot=<name>` with the backup token, staged as `.download.partial`,
  `.headers.partial` and `.manifest.partial` in the mirror. The copy is checked against the
  sender's headers and manifest (sha256, size, counts, every file in the tarball), must be at
  most two days old, and must not be older or hold fewer episodes or observations than the copy
  already held. Only then is it renamed to `chronicle-<stamp>.tar.gz` and, last,
  `chronicle-<stamp>.manifest.json`. A failed pull removes the three partials, keeps every
  published pair and exits non-zero.
- **Where it writes:** only directly inside `/mnt/nas/data1/docker/ms-chronicle/mirror`. No staging
  directory on d03, no rsync, no lock file elsewhere: a pull in flight is recognised by its
  partials (ones untouched for two hours are taken as left by a pull that died, and removed).
  The script does not create the mirror directory: if it is missing (NAS not mounted, first run
  not set up) the run fails and writes nothing.
- **Retention:** the newest pair. After a new pair is in place, older files named exactly
  `chronicle-<stamp>.tar.gz` or `chronicle-<stamp>.manifest.json` are deleted; nothing else in the
  directory is touched. History is nas01's ZFS snapshots of `data1/docker`, as for every app.
- **Token:** `MS_CHRONICLE_BACKUP_TOKEN` in `.env` (mode 600). It opens the two GETs above and
  nothing else; it cannot write. Source: the vault (`secret/v2/memory-system/chronicle-backup`),
  converged on the Mini by the memory-system deploy; delivered here from WS01 by
  `ms-chronicle-mcp/scripts/deliver-backup-token.sh`. It reaches curl on stdin, never argv, and is
  not sent to a URL that is not https.
- **Restore:** a person's action, on the Mini, and the operator's call: the contract's section
  "Restoring from a mirrored pair" has the commands. This script never restores.
- **Check:** `ms-chronicle-backup.sh verify`: the route answers 401 without a token and takes this
  one (it asks for the newest manifest, never the tarball), the mirror directory is there, and the
  newest pair has the sha256 and size its manifest recorded. Writes nothing.
- **Tests:** `scripts/tests/test_ms_chronicle_backup.sh` (offline, against a local stub of the
  contract) and `scripts/tests/test_ms_chronicle_backup_d04.sh` (the same cases on d04, into a temp
  directory; never the real mirror).
