# ns01

The first Pi-hole name server and the LAN's DHCP server, at **10.0.0.10** on Proxmox vmh01. ns02
(10.0.0.11, vmh02) is the other name server, DNS only.

A host in the build-new-and-cut-over form, as d06: this tree holds only `host.toml` (the build
spec), `apps/pihole/` and the updater files. It is built by `scripts/build_host.py ns01` from the
base build scripts in `build/setup/`, and nothing of the build stays on the host. A rebuild is a
replacement: a new VMID at the same address, restored from the NAS mirror, the old VM kept stopped
as the way back.

**Not built yet (draft, 2026-10-19).** The live ns01 is VM 300, built by the old `ns01/build.sh` and
`ns01/setup/` (removed here; see git history). Its old `~/update_scripts.sh` pulls `ns01/` from
GitHub `shepner/asyla` master, which origin's push mirrors: once this tree is on master, that
updater must not be run on VM 300 (it would install this tree over the old one). It runs only by
hand (no cron or timer; last run 2026-02-22). The `[vm]` values in `host.toml` follow ns02's (the
operator's, 2026-10-18). Cutover: asyla hub `runbooks/ns01-migration-cutover.md`.

## Layout

- `host.toml`: the build spec (VM, setup steps, the pihole app)
- `apps/pihole/`: Pi-hole (`pihole.sh`, `compose.yml`): backup, restore, verify, DHCP (on here only)
- `update_scripts.sh`, `update.sh`, `update_all.sh`: d06's updater files (the GitLab credential on
  stdin; no token file on the host)

## Build and verify (from the workstation)

```bash
python3 scripts/build_host.py ns01 plan      # read-only
python3 scripts/build_host.py ns01 verify    # read-only, once built
```

A build or destroy of ns01 needs `--confirm ns01` and the operator's approval of the exact action.
