# ns02 apps

All ns02 apps live here. Each has the same management pattern: a script (`pihole.sh`) with **up**, **down**, **logs**, and **pull**.

| App | Script | Notes |
|-----|--------|--------|
| **pihole** | `~/scripts/ns02/apps/pihole/pihole.sh` | Pi-hole DNS server (host network mode). Canonical **https://gitlab.com/asyla/pihole** (this repo keeps a deployable copy under `apps/pihole/`) |

Start after boot:

```bash
~/scripts/ns02/apps/pihole/pihole.sh up
```
