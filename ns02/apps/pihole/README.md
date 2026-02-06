# Pi-hole DNS Server (ns02)

Pi-hole DNS server running on ns02 (10.0.0.11). Provides DNS resolution and ad-blocking for the network.

## Prerequisites

- `~/scripts/docker/common.env` (DOCKER_DL, DOCKER_UID, DOCKER_GID, LOCAL_TZ)
- `/mnt/docker` (iSCSI) mounted
- `/mnt/nas/data2/docker/pihole/hosts` (NFS) available for custom hosts file
- `/mnt/nas/data2/docker/pihole/03-lan-dns.conf` (optional) for custom dnsmasq config

## Layout

- **Config/data:** `/mnt/docker/pihole-ns02/etc-pihole`, `/mnt/docker/pihole-ns02/etc-dnsmasq.d`
- **Custom hosts:** `/mnt/nas/data2/docker/pihole/hosts` (read-only mount)
- **Custom dnsmasq config:** `/mnt/nas/data2/docker/pihole/03-lan-dns.conf` (copied to container on start)

## Run

```bash
~/scripts/ns02/apps/pihole/pihole.sh up
```

The script automatically sources `~/scripts/docker/common.env` if it exists.

## Access

- **Web UI:** http://10.0.0.11/admin or http://pi.hole/admin
- **DNS:** 10.0.0.11:53 (TCP/UDP)
- **DHCP:** 10.0.0.11:67 (UDP) - if enabled

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
~/scripts/ns02/apps/pihole/pihole.sh up
```

If not set, Pi-hole will generate a random password (check logs).

### Custom DNS

Pi-hole uses upstream DNS servers:
- 1.1.1.1 (Cloudflare)
- 1.0.0.1 (Cloudflare)
- 2606:4700:4700::1111 (Cloudflare IPv6)
- 2606:4700:4700::1001 (Cloudflare IPv6)

### Custom Hosts File

Place custom hosts entries in `/mnt/nas/data2/docker/pihole/hosts` (mounted read-only).

### Custom dnsmasq Config

Place custom dnsmasq configuration in `/mnt/nas/data2/docker/pihole/03-lan-dns.conf`. This file is automatically copied to the container's `/etc/dnsmasq.d/` directory on start.

## Network Mode

Pi-hole uses `host` network mode to bind directly to ports 53, 67, 80, and 443 on the host. This is required for DNS and DHCP functionality.

## References

- [Pi-hole Documentation](https://docs.pi-hole.net/)
- [Pi-hole Docker Image](https://github.com/pi-hole/docker-pi-hole)
