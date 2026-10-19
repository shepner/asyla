# ns01 apps

All ns01 apps live here; `ns01/host.toml` lists them for the build. Each script follows the
host pattern: `up`, `down`, `restart`, `backup`, `restore`, `verify`, `update`, `logs`.

| App | Script | Notes |
|-----|--------|--------|
| **pihole** | `~/scripts/ns01/apps/pihole/pihole.sh` | Pi-hole DNS server and the LAN's DHCP server (host network mode) |
