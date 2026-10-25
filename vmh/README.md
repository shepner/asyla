# vmh: shared scripts for the Proxmox VE nodes

One set of scripts for all three hypervisors. They pull nothing and are configured from the
workstation over root SSH (asyla decision `hypervisor-scripts`).

| Node | Role | Address | Notes |
| --- | --- | --- | --- |
| vmh01 | production, cluster vmc01 | 10.0.0.35 | ZFS root, proxmox-boot-tool (GRUB), serial ttyS0 |
| vmh02 | production, cluster vmc01 | 10.0.0.36 | ZFS root, proxmox-boot-tool (GRUB), serial ttyS0 |
| vmh03 | production, cluster vmc01 (since 2026-10-23); testbed and canary | 10.0.0.37 | LVM root, plain GRUB (UEFI), USB NIC, no serial (`vmh03/`) |

vmh03 runs every new version first. A production `patch` installs a package only at a version vmh03
has run for `SOAK_DAYS` (7). All three are critical infrastructure (asyla CRI-1; vmh03 since it
joined vmc01): every changing mode needs the operator's approval of the exact command, and then
`--production`. `crashtest` runs on vmh03 only, and only while vmh01 and vmh02 keep quorum without it.
`health` reports `members` (every node in corosync.conf online, and the nodelist is vmh01 vmh02 vmh03).

## Commands (from the repo root)

```shell
vmh/apply.sh survey vmh01 vmh02 vmh03     # read-only facts, side by side (VMH_SURVEY_OUT=DIR keeps them)
vmh/apply.sh check vmh03 [PART...]       # read-only: does the node match setup.sh (those parts)?
vmh/apply.sh health vmh03                 # read-only: the checks host-maintenance runs
vmh/apply.sh patch vmh01 --plan           # read-only: what a patch would install or hold, and why
vmh/apply.sh setup vmh03 [PART...] --production   # repos updates crash netconsole-rx health swap
vmh/apply.sh patch vmh03 [--dry-run] --production # apt upgrade, no reboot
vmh/apply.sh kernel vmh03 VERSION --next-boot --production   # one trial boot; a panic (panic=10) falls back
vmh/apply.sh kernel vmh03 VERSION|none --production   # pin for every boot, or remove the pin
vmh/apply.sh cleanup vmh03 [--dry-run] --production   # old kernels by PVE's own keep list, apt cache
vmh/apply.sh crashtest vmh03 [--clean] --production   # vmh03 only: sysrq crash; did kdump save a vmcore?
vmh/usage.py [--node vmh01] [--window 2]  # read-only: guest load by hour of week, quietest windows
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
- **swap**: no swap on a ZFS zvol. It runs `swapoff` and comments out the fstab line, keeping the zvol
  and a copy at `/etc/fstab.before-asyla-swap`. vmh02 deadlocked on 2026-05-24 while swapping to
  `rpool/swap` (OpenZFS zvol write path, openzfs/zfs#18200, still open on 2026-10-24). It refuses if the
  swap holds more than half of MemAvailable.

## Kernel moves

A new kernel is installed by `patch` but does not boot until it is planned:

1. `kernel NODE NEW --next-boot`
2. Reboot in a window.
3. Check `uname -r` and `health`.
4. `kernel NODE NEW` to keep it, or reboot again to return to the pinned one.

The next-boot pin is PVE's: `/etc/kernel/next-boot-pin`, written into
`/etc/default/grub.d/proxmox-kernel-pin.cfg` and each ESP's grub.cfg. `proxmox-boot-cleanup.service`
removes it once the trial boot reaches systemd. A hang before that point boots the trial kernel again.
To get back, choose the old kernel under "Advanced options" in the GRUB menu at the console.

`cleanup` never removes the running, pinned, or two newest kernels (`/etc/apt/apt.conf.d/76pveconf`).
