# ns02

The second Pi-hole name server (DNS only), at **10.0.0.11** on Proxmox vmh02. ns01 (10.0.0.10) is
the other one and also the LAN's DHCP server.

A host in the build-new-and-cut-over form, as d06: this tree holds only `host.toml` (the build
spec), `apps/pihole/` and the updater files. It is built by `scripts/build_host.py ns02` from the
base build scripts in `build/setup/`, and nothing of the build stays on the host. A rebuild is a
replacement: a new VMID at the same address, restored from the NAS mirror, the old VM kept stopped
as the way back.

**Not built yet (2026-10-18).** The live ns02 is VM 301, built by the old `ns02/build.sh` and
`ns02/setup/` (removed here; see git history). It pulls nothing from GitLab, so this tree reaches
no running host. The `[vm]` values in `host.toml` are the operator's (2026-10-18).

## Layout

- `host.toml`: the build spec (VM, setup steps, the pihole app)
- `apps/pihole/`: Pi-hole (`pihole.sh`, `compose.yml`): backup, restore, verify, the DHCP guard
- `update_scripts.sh`, `update.sh`, `update_all.sh`: d06's updater files (the GitLab credential on
  stdin; no token file on the host)

## Build and verify (from the workstation)

```bash
python3 scripts/build_host.py ns02 plan      # read-only
python3 scripts/build_host.py ns02 verify    # read-only, once built
```

A build or destroy of ns02 needs `--confirm ns02` and the operator's approval of the exact action.
