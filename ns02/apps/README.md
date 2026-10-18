# ns02 apps

All ns02 apps live here; `ns02/host.toml` lists them for the build. Each script follows the
host pattern: `up`, `down`, `restart`, `backup`, `restore`, `verify`, `update`, `logs`.

| App | Script | Notes |
|-----|--------|--------|
| **pihole** | `~/scripts/ns02/apps/pihole/pihole.sh` | Pi-hole DNS server (host network mode); never DHCP |
