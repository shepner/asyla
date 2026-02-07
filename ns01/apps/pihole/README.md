# Pi-hole DNS Server (ns01)

Pi-hole DNS server running on ns01 (10.0.0.10). Provides DNS resolution and ad-blocking for the network.

## Prerequisites

- `~/scripts/docker/common.env` (DOCKER_DL, DOCKER_UID, DOCKER_GID, LOCAL_TZ)
- `/mnt/docker` (iSCSI) mounted, or another path for DOCKER_DL (see Migration below)
- `/mnt/nas/data2/docker/pihole/hosts` (NFS) available for custom hosts file
- `/mnt/nas/data2/docker/pihole/03-lan-dns.conf` (optional) for custom dnsmasq config

## Layout

- **Config/data:** `/mnt/docker/pihole-ns01/etc-pihole`, `/mnt/docker/pihole-ns01/etc-dnsmasq.d`
- **Custom hosts:** `/mnt/nas/data2/docker/pihole/hosts` (read-only mount)
- **Custom dnsmasq config:** `/mnt/nas/data2/docker/pihole/03-lan-dns.conf` (copied to container on start)

## Run

```bash
~/scripts/ns01/apps/pihole/pihole.sh up
```

The script automatically sources `~/scripts/docker/common.env` if it exists.

## Access

- **Web UI:** http://10.0.0.10/admin or http://pi.hole/admin
- **DNS:** 10.0.0.10:53 (TCP/UDP)
- **DHCP:** 10.0.0.10:67 (UDP) - if enabled

## Commands

- `pihole.sh up` — create dirs and start Pi-hole
- `pihole.sh down` — stop container
- `pihole.sh logs` — follow logs
- `pihole.sh pull` — pull image and up

## Configuration

### API Password

Set `PIHOLE_API_PASSWORD` in `~/scripts/docker/common.env` or pass via environment:

```bash
export PIHOLE_API_PASSWORD=your_password
~/scripts/ns01/apps/pihole/pihole.sh up
```

If not set, Pi-hole will generate a random password (check logs).

### Custom DNS

Pi-hole uses upstream DNS servers (IPv4 only by default):
- 1.1.1.1 (Cloudflare)
- 1.0.0.1 (Cloudflare)

IPv6 upstreams (e.g. 2606:4700:4700::1111) are not set because they produce "Network unreachable" connection errors when the network has no IPv6. To use them, add `DNS3`/`DNS4` in the compose environment and ensure the host has IPv6 connectivity.

### Custom Hosts File

Place custom hosts entries in `/mnt/nas/data2/docker/pihole/hosts` (mounted read-only).

### Custom dnsmasq Config

Place custom dnsmasq configuration in `/mnt/nas/data2/docker/pihole/03-lan-dns.conf`. This file is automatically copied to the container's `/etc/dnsmasq.d/` directory on start.

## Network Mode

Pi-hole uses `host` network mode to bind directly to ports 53, 67, 80, and 443 on the host. This is required for DNS and DHCP functionality.

## Migration from old ns01 (Alpine)

To use your existing Pi-hole data (gravity.db, etc.) on the new ns01 VM:

1. **Same volume path:** The new setup uses the same paths as the old script: `DOCKER_DL/pihole-ns01/etc-pihole` and `etc-dnsmasq.d`, and `DOCKER_D2/pihole/hosts`. So if you use iSCSI (`/mnt/docker`) and reconnect the same LUN, the data may already be there.
2. **Restore from backup:** If the new VM has empty storage, copy the old `etc-pihole` and `etc-dnsmasq.d` from the old host (or from an NFS/backup) into `/mnt/docker/pihole-ns01/` (or wherever DOCKER_DL points).
3. **Ownership:** The container runs as PIHOLE_UID:PIHOLE_GID (default 1003:1000). Ensure the host dirs are readable/writable by that user:
   ```bash
   sudo chown -R 1003:1000 /mnt/docker/pihole-ns01
   ```
   If your `common.env` uses DOCKER_GID=1001 (asyla), the container will use 1003:1001; then use `chown -R 1003:1001 ...` instead.

## Troubleshooting

### "Address in use" / "failed to create listening socket for port 53"

The host must not run another DNS service on port 53. The ns01 setup disables the systemd-resolved stub listener and any host dnsmasq. If you see this error on an existing ns01 that was built before that change, run once:

```bash
sudo ~/scripts/ns01/setup/systemConfig.sh
```

Then restart Pi-hole: `pihole.sh down && pihole.sh up`.

### "Database not available" (API)

FTL may log this when the web UI hits the API before the database is ready, or if the DB is locked. If the log also shows "Imported ... rows from the on-disk database", the data is being read; the message is often transient. If it persists:

- Ensure ownership of `etc-pihole` (and files inside) matches PIHOLE_UID:PIHOLE_GID (e.g. `chown -R 1003:1000 /mnt/docker/pihole-ns01/etc-pihole`).
- Restart Pi-hole: `pihole.sh down && pihole.sh up`.
- Check for stale lock files: `ls -la /mnt/docker/pihole-ns01/etc-pihole/*.db-*` and remove any if the container is stopped.

### "SQL error step DELETE: database is locked"

FTL logs this when SQLite cannot get a write lock (e.g. during `add_message` for dnsmasq/DHCP or upstream DNS messages). Common causes:

- **High write load** — Many DHCP/dnsmasq events or upstream errors cause concurrent writes; the compose file sets `FTLCONF_database_busytimeout=60000` (60s) so FTL waits longer for locks. `FTLCONF_dns_upstreams=1.1.1.1;1.0.0.1` forces IPv4-only upstreams and overrides any old config that still had IPv6 (which would cause connection errors and extra DB writes).
- **Database on network storage** — If `etc-pihole` is on iSCSI or NFS, lock latency can be higher. For persistent locks, consider moving the DB to local storage or increasing the timeout (e.g. `FTLCONF_database_busytimeout=60000` in your env or compose).
- **Stale locks** — After a crash, remove any `*.db-wal`, `*.db-shm` or other `*.db-*` files in `etc-pihole` only when the container is stopped.

If the lock error still mentions an IPv6 address (e.g. `2606:4700:4700::1111`), the persisted config likely still had that upstream; the compose file now sets `FTLCONF_dns_upstreams=1.1.1.1;1.0.0.1` so only IPv4 is used after a restart. If errors continue, try raising the busy timeout further or ensure `/etc/pihole` is on fast local disk.

### "SQLite3: recovered N frames from WAL file"

This appears when the container was stopped (or crashed) before FTL could checkpoint the Write-Ahead Log. SQLite recovers the frames on next start—data is not lost, but the message is noisy. The compose file sets `stop_grace_period: 45s` so `docker stop` / `pihole.sh down` give FTL time to shut down cleanly. If you still see it after host reboots or hard stops, it's harmless.

## References

- [Pi-hole Documentation](https://docs.pi-hole.net/)
- [Pi-hole Docker Image](https://github.com/pi-hole/docker-pi-hole)
