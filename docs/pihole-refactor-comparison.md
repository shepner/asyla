# Pi-hole: Old vs refactored config comparison

## Summary

| Item | Old (docker/pihole-ns0x.sh) | Refactored (ns0x/apps/pihole/) | Match? |
|------|----------------------------|---------------------------------|--------|
| **Image** | pihole/pihole:latest | pihole/pihole:latest | ✅ |
| **Container name** | ${NAME} → pihole-ns01 / pihole-ns02 | pihole-ns01 / pihole-ns02 | ✅ |
| **Data dir** | DOCKER_DL/${NAME} → pihole-ns01, pihole-ns02 | Same paths | ✅ |
| **Volumes** | etc-pihole, etc-dnsmasq.d, DOCKER_D2/pihole/hosts | Same | ✅ |
| **Network** | --net=host | network_mode: host | ✅ |
| **Upstream DNS** | 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, ::1001 | DNS1–DNS4 same | ✅ |
| **TZ, PIHOLE_UID, PIHOLE_GID** | From common.env | From common.env, same defaults | ✅ |
| **FTL listeningMode** | all | all | ✅ |
| **FTL dnssec** | true | true | ✅ |
| **FTL misc etc_dnsmasq_d** | true | true | ✅ |
| **API password** | empty (random) | PIHOLE_API_PASSWORD (empty default) | ✅ |
| **Capabilities** | NET_ADMIN, SYS_NICE | NET_ADMIN, SYS_NICE | ✅ |
| **03-lan-dns.conf** | doas cp to etc-dnsmasq.d before run | pihole.sh copies on `up` | ✅ |
| **Domain env var** | FTLCONF_dns_domain=${NAME}.${MY_DOMAIN} | FTLCONF_dns_domain_name=ns0x.asyla.org | ⚠️ See below |
| **Domain value** | pihole-ns01.asyla.org / pihole-ns02.asyla.org | ns01.asyla.org / ns02.asyla.org | ⚠️ Intentional |

## Differences

### 1. Domain environment variable name

- **Old:** `FTLCONF_dns_domain` (used in old script).
- **Refactored:** `FTLCONF_dns_domain_name` only (matches [Pi-hole FTL config](https://docs.pi-hole.net/ftldns/configfile/): `[dns.domain]` → `name` → env `FTLCONF_dns_domain_name`).

Current FTL does not recognize `FTLCONF_dns_domain` and logs a warning suggesting `FTLCONF_dns_domain_name`, so the refactored config uses only the documented variable.

### 2. Domain value (hostname vs container name)

- **Old:** `${NAME}.${MY_DOMAIN}` → **pihole-ns01.asyla.org** / **pihole-ns02.asyla.org**.
- **Refactored:** **ns01.asyla.org** / **ns02.asyla.org** (and container `hostname:` set to the same).

Refactored uses the host’s hostname (ns01/ns02), which matches the VM and is consistent with `hostname:` in the compose file. If you need exact parity with the old behavior (e.g. for DHCP or existing records), the value can be set back to pihole-ns01.asyla.org / pihole-ns02.asyla.org.

## Conclusion

Refactored config matches the old one for image, paths, volumes, network, DNS, TZ, UID/GID, capabilities, and 03-lan-dns.conf handling. The only deliberate differences are (1) using the documented `FTLCONF_dns_domain_name` and (2) using ns01.asyla.org / ns02.asyla.org as the domain (and hostname) instead of pihole-ns01.asyla.org / pihole-ns02.asyla.org.
