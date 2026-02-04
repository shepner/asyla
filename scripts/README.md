# Migration Scripts

## migrate-app.sh

Simple script to migrate Docker applications between hosts. Uses rsync to copy data from the source host's iSCSI drive to the destination host's iSCSI drive.

### Why This Exists

Each Docker host (d01, d02, d03) has its own iSCSI drive mounted at `/mnt/docker` to avoid NFS file locking issues with databases (especially SQLite). However, this makes migrating applications between hosts difficult. This script automates the migration process.

### Prerequisites

**On Source Host:**
1. SSH access as `docker` user
2. SSH keys configured for docker user (see setup scripts)
3. `rsync` installed
4. Sudo/doas access configured for rsync (see below)

**On Destination Host:**
1. SSH access as `docker` user
2. SSH keys configured for docker user (see setup scripts)
3. `rsync` installed
4. Sudo/doas access to create directories and set permissions

**One-time Setup on Source Host:**

Add rsync to sudoers/doas (required for rsync over SSH to work):

```bash
# On source host (Ubuntu/Debian)
sudo visudo
# Add this line:
docker ALL=NOPASSWD:/usr/bin/rsync

# On source host (Alpine)
doas visudo
# Add this line:
permit nopass docker as root cmd /usr/bin/rsync
```

### Usage

```bash
./migrate-app.sh <app-name> <source-host> <dest-host> [--dry-run] [--cleanup-source]
```

**Examples:**

```bash
# Dry run to see what would happen
./migrate-app.sh sonarr d01 d03 --dry-run

# Migrate sonarr from d01 to d03
./migrate-app.sh sonarr d01 d03

# Migrate and remove container from source
./migrate-app.sh sonarr d01 d03 --cleanup-source
```

### What It Does

1. **Checks** if container exists on source host
2. **Stops** the container on source host
3. **Verifies** source data path exists (`/mnt/docker/<app-name>`)
4. **Creates** destination directory on destination host
5. **Syncs** data using rsync (preserves permissions, shows progress)
6. **Sets** proper ownership (docker:asyla) on destination
7. **Optionally** removes container from source (if `--cleanup-source` flag used)

### After Migration

The script will **not** automatically start the container on the destination. You need to do this manually:

**For docker-compose (d03):**
```bash
ssh docker@d03 'cd ~/scripts/d03 && docker compose up -d sonarr'
```

**For shell scripts (d01/d02):**
```bash
ssh docker@d01 '~/scripts/docker/sonarr.sh'
```

### Important Notes

- **Always test with `--dry-run` first** to verify paths and permissions
- **Stop the old container** before starting the new one to avoid conflicts
- **Verify the migration** works before cleaning up the source
- **Data remains on source** unless you manually delete it (even with `--cleanup-source`)
- The script preserves file permissions and ownership during transfer

### Troubleshooting

**Permission denied errors:**
- Verify sudoers configuration on source host
- Check that rsync is in the correct path (`which rsync`)

**Container not found:**
- Verify the app name matches exactly (case-sensitive)
- For docker-compose apps, check `docker compose ps` output

**rsync fails:**
- Check SSH connectivity: `ssh docker@<host>`
- Verify SSH keys are configured: `ssh docker@<host> "echo 'SSH works'"` (should not prompt for password)
- **Important**: Source host must be able to SSH to destination host. Test from source: `ssh docker@<dest-host> "echo test"`
- Verify iSCSI mounts are available: `mount | grep docker`
- Check disk space on destination: `df -h /mnt/docker`
- Verify rsync is installed on source host: `ssh docker@<source-host> "which rsync"`

### Related Documentation

- See `d02/plex_migration_notes.md` for manual migration example
- See `d03/docs/runbook-migrate-from-d01.md` for application migration runbook
