# ms-procedural-backup (d03)

Nightly off-host backup of **ms-procedural**, theOrg's procedural memory (formerly agent-commons),
which runs on the Mac Mini. d03 pulls a consistent SQLite copy over HTTPS and keeps it in the NAS
mirror, because the Mini has no off-host path for Docker volumes (theOrg plan
`ms-procedural-rename.plan.md`, D8, EA 2026-10-08).

- **When:** host-maintenance's `backup d03` schedule (03:00 America/Chicago) runs
  `ms-procedural-backup.sh backup` with every other d03 app.
- **What:** `GET https://ms-procedural.asyla.org/api/v1/backup` with the backup token → integrity and
  row counts checked against the sender's headers → `/mnt/docker/ms-procedural-backup/procedural.db`
  → rsync mirror to `/mnt/nas/data1/docker/ms-procedural/mirror` (history: nas01 ZFS snapshots).
- **Token:** `MS_PROCEDURAL_BACKUP_TOKEN` in `.env`. It opens the backup route only, and reads; it
  cannot write. Source: the vault (`secret/v2/memory-system/procedural-backup`), converged by the
  memory-system deploy; delivered here by `ms-procedural/scripts/deliver-backup-token.sh` (WS01).
- **Restore:** stop `ms-procedural-1` on the Mini, then copy `procedural.db` from the mirror (or a
  ZFS snapshot of it) into the `ms-procedural-data` volume with
  `ms-procedural/scripts/seed-from-agent-commons.sh`'s swap step as the model (remove the old
  `-wal`/`-shm`), start, and check `/api/v1/health`.
- **Check:** `ms-procedural-backup.sh verify` (downloads nothing).
