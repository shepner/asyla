# vmh: shared scripts for the Proxmox VE nodes

One set of scripts for all three hypervisors. They pull nothing and are configured from the
workstation over root SSH (asyla decision `hypervisor-scripts`).

| Node | Role | Address | Notes |
| --- | --- | --- | --- |
| vmh01 | production, cluster vmc01 | 10.0.0.35 | ZFS root, proxmox-boot-tool (GRUB), serial ttyS0 |
| vmh02 | production, cluster vmc01 | 10.0.0.36 | ZFS root, proxmox-boot-tool (GRUB), serial ttyS0 |
| vmh03 | testbed and canary, standalone | 10.0.0.37 | LVM root, plain GRUB (UEFI), USB NIC, no serial; corosync-qnetd (`vmh03/`) |

vmh03 runs every new version first. A production `patch` installs a package only at a version vmh03
has run for `SOAK_DAYS` (7). vmh01 and vmh02 are critical infrastructure (asyla CRI-1): every
changing mode there needs the operator's approval of the exact command, and then `--production`.

## Commands (from the repo root)

```shell
vmh/apply.sh survey vmh01 vmh02 vmh03     # read-only facts, side by side (VMH_SURVEY_OUT=DIR keeps them)
vmh/apply.sh check vmh03                  # read-only: does the node match setup.sh?
vmh/apply.sh health vmh03                 # read-only: the checks host-maintenance runs
vmh/apply.sh patch vmh01 --plan           # read-only: what a patch would install or hold, and why
vmh/apply.sh setup vmh03 [PART...]        # repos updates crash netconsole-rx health
vmh/apply.sh patch vmh03 [--dry-run]      # apt upgrade, no reboot
vmh/apply.sh kernel vmh03 VERSION --next-boot   # one trial boot; a panic (panic=10) falls back
vmh/apply.sh kernel vmh03 VERSION|none    # pin for every boot, or remove the pin
vmh/apply.sh cleanup vmh03 [--dry-run]    # old kernels by PVE's own keep list, apt cache
```

## Parts (`setup`)

- **repos**: pve-no-subscription on; pve-enterprise and ceph off.
- **updates**: unattended-upgrades. vmh03 takes every origin, as the canary. Production takes Debian
  security only: no kernel, no Proxmox stack, never a reboot, never a removal.
- **crash**: one `/etc/sysctl.d/99-crashdebug.conf` (panic=10 and the panic_on_* set;
  `vm.panic_on_oom = 0`, so an OOM kills one guest rather than the node), kdump-tools with
  `MODULES=most` and `crashkernel` sized by RAM, the serial console where the board has one, and
  netconsole to vmh03. The netconsole is set up through configfs after vmbr0 exists, because the
  modprobe option failed at boot on vmh02.
- **netconsole-rx**: vmh03 only. It accepts UDP 6666 from vmh01/vmh02 and writes
  `/var/log/netconsole/<node>.log` with receive times.
- **health**: `/usr/local/sbin/asyla-vmh-health` (read-only), plus one line in root's
  authorized_keys. That line lets host-maintenance's d03 runner key run the health check, and nothing
  else.

## Kernel moves

A new kernel is installed by `patch` but does not boot until it is planned:

1. `kernel NODE NEW --next-boot`
2. Reboot in a window.
3. Check `uname -r` and `health`.
4. `kernel NODE NEW` to keep it, or reboot again to return to the pinned one.

`cleanup` never removes the running, pinned, or two newest kernels (`/etc/apt/apt.conf.d/76pveconf`).
