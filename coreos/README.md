# CoreOS

Fedora [CoreOS](https://getfedora.org/en/coreos) host running as a Proxmox VM

[Fedora CoreOS Documentation](https://docs.fedoraproject.org/en-US/fedora-coreos/fcos-projects/)


## Install Fedora CoreOS on Proxmox

[[TUTORIAL] HOWTO : Wrapper Script to Use Fedora CoreOS Ignition with Proxmox cloud-init system for Docker workloads](https://forum.proxmox.com/threads/howto-wrapper-script-to-use-fedora-coreos-ignition-with-proxmox-cloud-init-system-for-docker-workloads.86494/)
* Full explanation wiki : https://wiki.geco-it.net/public:pve_fcos
* Source code: https://git.geco-it.net/GECO-IT-PUBLIC/fedora-coreos-proxmox

Proxmox VE use Cloud-Init as a provisionning tool for Virtual Machines (VM) Cloud-Init but Fedora CoreOS is only compatible with “Ignition”.  Geco-iT made a wrapper that converts the Cloud-Init config of Proxmox to an Ignition compatible config

The wrapper takes care of the following parameters:
* Username ; by default = admin
* Password
* DNS Domain
* DNS server(s)
* SSH Key(s)
* IP configuration(s) but only IPv4

The tool will automatically:
1) Download the Fedora CoreOS Image
2) Create a virtual Machine
3) Import the Fedora CoreOS as a VM Disk
4) Add a cloud init config drive to that VM
5) Add the « hook-script » hook-fcos.sh at VM startup
6) Copy the Ignition template in a « Proxmox snippet » storage
7) Convert the VM to a Template that you can use after


### Prerequisites

To activate a Proxmox snippet storage:
On the Proxmox WebUI: DATACENTER ⇒ STORAGE ⇒ <nas-data2-vm> ⇒ Content ⇒ Select « Snippets »


SSH into the Proxmox host and run the following:


``` shell
# git install
# apt install git

cd /mnt/nas/data1/vm

# downloading sources files
git clone https://git.geco-it.net/GECO-IT-PUBLIC/fedora-coreos-proxmox.git

cd fedora-coreos-proxmox
```


### Configuration

``` shell
vi vmsetup.sh
```

Adjust the following params as appropriate:
* TEMPLATE_VMID=“900”
* TEMPLATE_VMSTORAGE=“nas-data1-vm”
* SNIPPET_STORAGE=“nas-data1-vm”

### Create template

``` shell
./vmsetup.sh 
```

The script generates the base `fcos-base-tmplt.yaml` ignition file.  This config will:
* Correct fstrim service (Proxmox Discard Option)
* Install the Qemu-guest-agent at first boot (network need to be operational)
* Install the Geco-iT CloudInit wrapper script (reconfiguration if a change is detected in the Proxmox Cloud-Init config)
* Change the console log level from DEBUG (7) to WARNING (4)
* Add the Geco-iT motd/issue

For more advanced settings, please check the documentation at https://docs.fedoraproject.org/en-US/fedora-coreos/

NFS: https://discussion.fedoraproject.org/t/fedora-coreos-nfs-mount/27453


### Deploy a Fedora CoreOS VM

In the Proxmox web UI, find the `fcos-tmplt` VM/template:
* Adjust the hardware settings
* Adjust the Cloud-Init settings
* right-click > Clone, provide name

Select the resulting VM:
* Adjust specific settings for VM
* Start

The VM will proceed to self update and reboot for a while until it is current.

switch to the console and login as `admin`

https://docs.fedoraproject.org/en-US/fedora-coreos/running-containers/

