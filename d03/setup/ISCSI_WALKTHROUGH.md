# iSCSI Setup Walkthrough (iscsi.sh)

Step-by-step guide to what `iscsi.sh` does, what you must do by hand, and how to verify.

## Prerequisites (manual)

- **TrueNAS (nas01)** reachable from d03 (e.g. `ping 10.0.0.24`).
- **Target exists**: iSCSI target `iqn.2005-10.org.freenas.ctl:nas01:d03:01` is configured on TrueNAS.
- **Initiator access**: The initiator group for this target will need the **new** d03’s IQN (see step 2 below). If this is a new VM, the old d03 IQN in TrueNAS must be replaced with the new one after open-iscsi is installed.
- **Old d03**: If you rebuilt d03, the old VM should be shut down/destroyed so the LUN isn’t connected elsewhere.

---

## Step 1: Run the script (interactive start)

```bash
sudo ~/scripts/d03/setup/iscsi.sh
# or
sudo ~/setup_scripts_to_d03.sh   # if you have a similar symlink
```

The script **requires root** and will **prompt once** at the beginning.

---

## Step 2: Script block – “TrueNAS verification” (manual decision)

**What the script does:** Prints a warning and asks:

```text
Have you verified TrueNAS iSCSI configuration? (yes/no):
```

**You must:** Type **yes** (lowercase) and press Enter. Any other input exits the script.

**Manual checklist before typing “yes”:**

- [ ] Logged into TrueNAS (nas01).
- [ ] Target `iqn.2005-10.org.freenas.ctl:nas01:d03:01` exists.
- [ ] You know you’ll add the **new d03 initiator IQN** to the initiator group (see Step 4).

---

## Step 3: Script block – Install open-iscsi and start iscsid

**What the script does:**

- `apt update` and `apt install -y open-iscsi`
- `systemctl enable iscsid` and `systemctl start iscsid`
- Sleeps 2 seconds

**Manual:** None. Needs network (apt) and will create `/etc/iscsi/initiatorname.iscsi` with this host’s IQN (e.g. `iqn.2016-04.com.open-iscsi:xxxxx`).

---

## Step 4: Get new initiator IQN and update TrueNAS (script pauses here)

**What the script does:** After installing and starting iscsid, it prints this host’s initiator name and waits: “Add this initiator to the target’s Initiator Group on TrueNAS, then press Enter to continue.” TrueNAS only allows initiators that are in the target’s initiator group. If the group still has the **old** d03 IQN, the next step (login) will fail.

**You do:**

1. The script shows the initiator name on screen (from `/etc/iscsi/initiatorname.iscsi`). Example: `InitiatorName=iqn.2016-04.com.open-iscsi:abc123def456`

2. On TrueNAS (nas01):
   - Go to **Sharing → Block (iSCSI) → Initiator Groups**.
   - Find the group used by target `nas01:d03:01` (e.g. “Group 3”).
   - Replace the old d03 initiator IQN with the value from step 1 (or add it if the group allows multiple).
   - Save.

3. Back on d03, press **Enter** in the terminal. The script will then attempt login (Step 5).

---

## Step 5: Script block – Connect to iSCSI target (login)

**What the script does:**

- Uses target `iqn.2005-10.org.freenas.ctl:nas01:d03:01` and portal `10.0.0.24`.
- Runs: `iscsiadm --mode node --targetname ... --portal ... --login`.
- On success: sets the node to start automatically on boot (`node.conn[0].startup = automatic`).
- On failure: prints an error and **exits**. No fstab or mount point is written.

**Manual:** If login fails:

- Confirm TrueNAS initiator group has this host’s IQN (Step 4).
- From d03: `ping 10.0.0.24`, `systemctl status iscsid`.
- On TrueNAS: no other host should be using this LUN (e.g. old d03 shut down).

---

## Step 6: Script block – Wait and detect iSCSI block device

**What the script does:**

- Sleeps 3 seconds.
- Scans `/dev/sd[b-z]` and `/dev/sd[a-z][a-z]` for a block device that is:
  - Not a mount point, and
  - Not already in `/etc/fstab`.
- Picks the **first** such device as the iSCSI device.

**Manual:** If the VM has more than one extra disk, the script might choose the wrong one. In that case it will exit with “Could not automatically detect iSCSI device” and tell you to run `lsblk` or `fdisk -l` and update fstab yourself. For a single system disk + one iSCSI LUN, this is usually correct.

---

## Step 7: Script block – Check if device is formatted

**What the script does:**

- Runs `blkid` on the chosen device.
- If the device has no partition table/filesystem, it prints a warning and **exits** with instructions to partition and format manually.

**Manual (first-time LUN):** If TrueNAS presents a **raw** LUN (no partition table):

1. Note the device (e.g. `/dev/sdb` from the script’s last message or from `lsblk`).
2. Partition and format (destructive):
   ```bash
   sudo fdisk /dev/sdb    # create one partition (e.g. n, p, 1, Enter, Enter, w)
   sudo mkfs.ext4 /dev/sdb1
   ```
3. Run `iscsi.sh` again (or add the fstab entry and mount point yourself).

---

## Step 8: Script block – Find partition and mount point

**What the script does:**

- Finds the first partition on the iSCSI device (e.g. `/dev/sdb1`).
- If none: exits with instructions to partition/format (same as Step 7).
- Creates `/mnt/docker`, `chown docker:asyla`, `chmod 755`.
- If `/mnt/docker` is not in `/etc/fstab`:
  - Gets UUID of the partition (`blkid -s UUID -o value`).
  - Appends: `UUID=... /mnt/docker ext4 _netdev,rw,noauto 0 0` (or device path if no UUID).
- Runs `apt autoremove` / `apt autoclean` and prints success.

**Manual:** None if the script completes. The script uses **noauto**, so the filesystem is **not** mounted at the end. You must mount once (and after each reboot if you don’t add a mount service):

```bash
sudo mount /mnt/docker
```

---

## Summary: What you must do by hand

| Step | Action |
|------|--------|
| Before script | Ensure target exists on TrueNAS, old d03 disconnected, network OK. |
| Script prompt | Type **yes** when asked about TrueNAS verification. |
| When script pauses | Add the shown initiator IQN to the target’s initiator group on TrueNAS, then press Enter. |
| First-time raw LUN | If script exits at “device does not appear to be formatted”: partition and format the iSCSI device, then re-run the script (or add fstab and mount manually). |
| After script | Run `sudo mount /mnt/docker` (and optionally add a systemd mount or boot script if you want it mounted on boot). |

---

## Quick verification after setup

```bash
# Session and device
iscsiadm -m session
lsblk
sudo mount /mnt/docker
df /mnt/docker
```

---

## Script behavior summary

- **Interactive (TTY):** Prompts for "yes" and "press Enter" after showing the initiator name.
- **Non-interactive:** Skips prompts; prints initiator name and proceeds with discovery + login. If you haven’t added the initiator on TrueNAS yet, login fails and the script tells you to add it and re-run.
- **Discovery:** The script runs `iscsiadm -m discovery -t sendtargets -p 10.0.0.24` before login so the node exists in the local DB (required for login to succeed).
- **After-the-fact:** Run `sudo ~/setup_iscsi_connect.sh` once the initiator is in TrueNAS. It does discovery, login, set automatic, device detection, fstab, and mount with no prompts (assumes open-iscsi is already installed).
