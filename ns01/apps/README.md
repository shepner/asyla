# ns01 apps

All ns01 apps live here. Each has the same management pattern: a script (`pihole.sh`) with **up**, **down**, **logs**, and **pull**.

| App | Script | Notes |
|-----|--------|--------|
| **pihole** | `~/scripts/ns01/apps/pihole/pihole.sh` | Pi-hole DNS server (host network mode). **`pihole` is a symlink** → **`asyla/projects/pihole/hosts/ns01`**; canonical **https://gitlab.com/asyla/pihole** |

Start after boot:

```bash
~/scripts/ns01/apps/pihole/pihole.sh up
```
