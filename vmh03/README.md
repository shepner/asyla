# vmh03

Lenovo ThinkCentre M90n-1 Nano running Proxmox VE 9. Since 2026-10-23 it is the third member of
cluster vmc01 (with vmh01 and vmh02): any two of the three keep quorum. It joined in place of the
qdevice it was first built for (asyla hub decision `vmc01-quorum-third-vote`, L3). It is critical
infrastructure (CRI-1) like vmh01 and vmh02, and stays the testbed and canary: new versions run here
first (`vmh/`).

Like vmh01 and vmh02 it pulls nothing; it is configured from the workstation (asyla decision
`hypervisor-scripts`). Its node configuration is the shared `vmh/` (`vmh/apply.sh ... vmh03
--production`); this folder holds only its facts check and the removal of the old qnetd role.

| | |
| --- | --- |
| Address | 10.0.0.37/24 on VLAN 100, gateway 10.0.0.1, DNS 10.0.0.10 |
| Name | `vmh03.asyla.org` (Pi-hole hosts file line `10.0.0.37 vmh03`) |
| Switch | switch2 copper access port in VLAN 100 (a USB 3 GbE adapter; the onboard I219 fails its PHY probe; Wi-Fi unused) |
| Storage | `local` and `local-lvm` (LVM thin `pve/data`), limited to vmh03 in the cluster's `storage.cfg` |

## Install (operator, at the box)

1. BIOS: power on after AC loss; VT-x on.
2. Proxmox VE 9 ISO: hostname `vmh03.asyla.org`, address 10.0.0.37/24, gateway 10.0.0.1,
   DNS 10.0.0.10, time zone America/Chicago.
3. From the workstation, once: `ssh-copy-id -i ~/.ssh/shepner_rsa.pub root@10.0.0.37` (root password).
4. Rejoin after a reinstall: `pvecm delnode vmh03` on a remaining member first, then the join steps
   in the decision (limit storages, `pvecm add 10.0.0.35`, `local-lvm` for vmh03, `vmh/` setup).

## From the workstation

```shell
vmh03/apply.sh check                       # read-only: facts, ssh host keys, no qnetd left
vmh03/apply.sh remove-qnetd --production   # once, after the join: purge corosync-qnetd and its firewall
```

`remove-qnetd` is idempotent. It purges `corosync-qnetd` first, then stops and removes
`asyla-qnetd-firewall.service`, the nft table `inet asyla_qnetd` and `/etc/asyla/qnetd.nft`, so TCP
5403 is never open while the daemon listens. It lists what `apt autoremove` would take (the
`libnss3-tools` qnetd pulled in) without running it.
