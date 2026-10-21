# vmh03

Lenovo ThinkCentre M90n-1 Nano running standalone Proxmox VE 9. It is **not** a member of cluster
vmc01 (vmh01 + vmh02). Its job is vmc01's third quorum vote: `corosync-qnetd` on the host, from
Debian trixie main. Why and the full plan: asyla hub decision `vmc01-quorum-third-vote`.

Like vmh01 and vmh02 it pulls nothing; it is configured from the workstation (asyla decision
`hypervisor-scripts`). Once it carries the vote, treat it as critical infrastructure.

| | |
| --- | --- |
| Address | 10.0.0.37/24 on VLAN 100, gateway 10.0.0.1, DNS 10.0.0.10 |
| Name | `vmh03.asyla.org` (Pi-hole hosts file line `10.0.0.37 vmh03`) |
| Switch | switch2 copper access port in VLAN 100 (one GbE port; Wi-Fi unused) |
| Open to | TCP 5403 from 10.0.0.35 and 10.0.0.36 only (nft table `inet asyla_qnetd`) |

## Install (operator, at the box)

1. BIOS: power on after AC loss, if offered; VT-x on.
2. Proxmox VE 9 ISO: hostname `vmh03.asyla.org`, address 10.0.0.37/24, gateway 10.0.0.1,
   DNS 10.0.0.10, time zone America/Chicago.
3. From the workstation, once: `ssh-copy-id -i ~/.ssh/shepner_rsa.pub root@10.0.0.37` (root password).

## Configure (workstation, from this repo)

```shell
vmh03/apply.sh check     # read-only: hardware facts, ssh host-key fingerprints, state
vmh03/apply.sh setup     # repos as vmh02, TCP 5403 rule, corosync-qnetd; then check
```

`setup` is idempotent: it leaves the pve-no-subscription repo enabled and the enterprise and
Ceph repos disabled, as on vmh02. It installs `/etc/asyla/qnetd.nft` with its unit
`asyla-qnetd-firewall.service` (ordered before corosync-qnetd), then `corosync-qnetd`. It does not
upgrade packages.

## Joining the vote to vmc01

`pvecm qdevice setup 10.0.0.37`, run on vmh01, does `ssh-copy-id` with vmh01's
`/root/.ssh/id_rsa` and then uses root SSH to vmh03 to sign certificates. Authorize that key only
for the setup:

```shell
vmh03/apply.sh add-setup-key       # before pvecm qdevice setup
vmh03/apply.sh remove-setup-key    # after it; qdevice remove needs no SSH to vmh03
```

vmh01 asks once to accept vmh03's host key; compare with the fingerprints `check` prints.
