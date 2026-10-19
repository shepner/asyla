# Pi-hole DNS Server (ns01)

Pi-hole DNS server on ns01 (10.0.0.10): DNS and ad-blocking for the LAN, and the LAN's DHCP server.
ns02 (10.0.0.11) is the other name server (DNS only); only this copy serves DHCP (below).

## Prerequisites

- `~/scripts/docker/common.env` (DOCKER_DL, DOCKER_D1, DOCKER_D2, DOCKER_UID, DOCKER_GID, LOCAL_TZ)
  and `~/scripts/docker/backup_lib.sh`, installed by the updater
- `/mnt/docker`: the host's data disk (the build's `disk` phase)
- `/mnt/nas/data2/docker/pihole/hosts` (NFS, `nfs.sh`): the LAN hosts file. **`up` refuses to start
  without it.** It stays on the NAS by design: central, snapshotted, reachable when everything else
  is down, and never in a repo (it is a map of the network).
- `/mnt/nas/data2/docker/pihole/03-lan-dns.conf` (optional): copied into `etc-dnsmasq.d` at `up`
- Port 53 free on the host (`build/setup/dns_port.sh`, a setup step in `ns01/host.toml`)

## Layout

- **Config/data:** `/mnt/docker/pihole-ns01/etc-pihole`, `/mnt/docker/pihole-ns01/etc-dnsmasq.d`
- **Hosts file:** `/mnt/nas/data2/docker/pihole/hosts`, mounted read-only as the container's `/etc/hosts`
- **Backup:** one rsync mirror at `/mnt/nas/data1/docker/pihole-ns01/mirror` (`docker/backup_lib.sh`):
  `etc-pihole/` and `etc-dnsmasq.d/` only, without `pihole-FTL.db` (query history). History is the
  NAS's ZFS snapshots of that share.

## Commands

- `pihole.sh up`: check the NAS hosts file, create the data dirs, copy `03-lan-dns.conf`, start
- `pihole.sh down` / `restart`
- `pihole.sh backup`: mirror the data to the NAS (in screen when run from a terminal); refused on
  any host but ns01, so a replica never writes ns01's mirror
- `pihole.sh restore`: from the mirror into an empty data dir (stop the app first); refuses over data
- `pihole.sh verify`: the container healthy, the NAS hosts file mounted, a CNAME and a hosts-file
  name answering, the host's own name answering its address (not 0.0.0.0), an outside name answering
  (not on a replica), `dhcp.active` as the host should have
  it, `wpad`, the allowlist; warns when no admin password is set
- `pihole.sh password`: set the admin password from stdin (below)
- `pihole.sh update` (pull only) / `refresh` (pull, then up)
- `pihole.sh logs`

## Configuration

Settings are pinned in `compose.yml` as `FTLCONF_` lines. Pi-hole makes a setting given that way
read-only in the web UI and the API, so the two name servers cannot drift apart. Change a setting
in `compose.yml`, then `pihole.sh restart`. Data that is not a setting stays in `etc-pihole/` and
travels in the backup: the CNAMEs (written by the asyla/pihole pipeline through the API), domain
lists, gravity.

### DHCP guard

`FTLCONF_dhcp_active=${PIHOLE_DHCP_ACTIVE:-false}`, and `pihole.sh` sets `PIHOLE_DHCP_ACTIVE=true`
only when `hostname -s` is `ns01`. Pi-hole cannot run redundant DHCP, so a second DHCP server on the
LAN (a test01 replica, a copy on the wrong host) must never happen; `verify` checks `dhcp.active`
and that udp/67 listens on ns01 and nowhere else.

### DHCP (ns01)

- Range `10.0.0.100`-`10.0.0.254`, router `10.0.0.1`, lease time `6h`, no IPv6, no rapid commit:
  pinned in `compose.yml` as `FTLCONF_dhcp_*` (as on VM 300, 2026-10-19), so read-only in the UI.
- Reservations (`dhcp.hosts`): editable in the web UI (operator, 2026-10-18); kept in
  `etc-pihole/pihole.toml`, so they travel in the mirror.
- Leases: `etc-pihole/dhcp.leases`, in the mirror, so a rebuilt ns01 knows the leases it gave.
- The DNS servers a lease names (`10.0.0.10,10.0.0.11`): `03-lan-dns.conf` from the NAS.

### Admin password

Set once with `pihole.sh password`, the value on stdin (never argv; from OpenBao). It starts the
container once with `FTLCONF_webserver_api_password` in its environment (`compose.admin-login.yml`),
then again without it, and checks that the value logs in to the API. Pi-hole keeps only the hash in
`etc-pihole/pihole.toml`, so restarts and the restore keep the password. `compose.yml` never sets
it: given that way, Pi-hole makes it read-only, and an empty value removes it at every start. While
no hash is set (a new data dir), `up` starts with an empty value, so the image does not make up a
random password and print it to the container log; `up` and `verify` warn.

The asyla/pihole CNAME pipeline writes through this API, so it needs the same value as GitLab CI
variable `PIHOLE_API_PASSWORD_NS01` (ns02: `..._NS02`), or it gets 401.

Pi-hole's own `pihole setpassword` is not used: it passes the value to `pihole-FTL --config` as an
argument (`/opt/pihole/utils.sh` in the image, 2026.05.0).

### Local DNS record and allowlist (both servers)

- `FTLCONF_dns_hosts=255.255.255.255 wpad`: no client auto-discovers a web proxy (WPAD hijack).
  Every other local name is the NAS hosts file.
- `FTLCONF_dns_reply_host_force4=false`: the host's own name answers the address the query arrived
  on. On 2026-10-19 a restore carried an old `pihole.toml` with it true and no IPv4, and the name
  answered 0.0.0.0; pinned, a restore cannot carry it again.
- `allowlist`: exact domains allowed although the adlist blocks them. `up` adds each with
  `pihole allow` (a no-op when present); `verify` checks them. Entries added by hand stay.

### Custom DNS

Pi-hole uses upstream DNS servers (IPv4 only by default):
- 1.1.1.1 (Cloudflare)
- 1.0.0.1 (Cloudflare)

IPv6 upstreams (e.g. 2606:4700:4700::1111) are not set because they produce "Network unreachable" connection errors when the network has no IPv6. To use them, add them to `FTLCONF_dns_upstreams` in `compose.yml` once the host has IPv6 connectivity.

### Custom Hosts File

Place custom hosts entries in `/mnt/nas/data2/docker/pihole/hosts` (mounted read-only).

### Custom dnsmasq Config

Place custom dnsmasq configuration in `/mnt/nas/data2/docker/pihole/03-lan-dns.conf`. This file is automatically copied to the container's `/etc/dnsmasq.d/` directory on start.

### "not giving name … to the DHCP lease because the name exists in /etc/hosts" (ns01, the DHCP server)

That warning means the device is getting a **different** IP from DHCP (e.g. 10.0.0.243) than the IP you have for its hostname in `/etc/hosts` (e.g. 10.0.0.82). dnsmasq won't attach the hostname to the lease because it would conflict with the static hosts entry, so the device keeps its current lease and the message repeats.

**Fix:** Add a **DHCP reservation** (static lease) so the device is always assigned the same IP as in `/etc/hosts`. In `03-lan-dns.conf` add:

```conf
# MAC, hostname, IP — use the IP that matches your hosts file
dhcp-host=AA:BB:CC:DD:EE:FF,hdhr-1052f1a2,10.0.0.82
```

Replace `AA:BB:CC:DD:EE:FF` with the device's MAC (from Pi-hole Admin → Local DNS → DHCP leases, or the lease list for the current 10.0.0.243 lease). After copying the updated config and restarting Pi-hole, the device will get 10.0.0.82 on its next DHCP request/renew; then the hostname and IP match and the warnings stop. Repeat for any other hosts (e.g. hdhr-10516dac → 10.0.0.83).

## Network Mode

Pi-hole uses `host` network mode to bind directly to ports 53, 67, 80, and 443 on the host. This is required for DNS and DHCP functionality.

## Troubleshooting

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
