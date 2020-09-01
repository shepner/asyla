# proxmox-blueiris

## Create the VM

run the following

``` shell
bash <(curl -s https://raw.githubusercontent.com/shepner/proxmox-blueiris/master/proxmox/create_vm.sh)
```

## Install Windows

Follow the installer steps until you reach the installation type selection where you need to select "Custom (advanced)"

Now click "Load driver" to install the VirtIO drivers for hard disk and the network:

* Hard disk: Browse to folder `vioscsi\w10\amd64` and install the driver
* Network: Browse to folder `NetKVM\w10\amd64` and install the driver
* Memory Ballooning: Browse to folder `Balloon\w10\amd64` and install the driver 

Choose the drive and continue the Windows installer steps:

* Turn off all the MS Spyware options
* skip the Android sync
* turn off the OneDrive backup
* Skip 365 trial
* Skip Cortina

After Windows starts, 

* Install the "Qemu Guest Agent". The installer is located on the driver CD under `guest-agent\qemu-ga-x86_64.msi`
* Install `virtio-win-gt-x64.msi` found on the root of the CD

Shutdown the VM

Set the MAC address in the DHCP server

Start the VM

From the commandline, run `ipconfig /release` and `ipconfig /renew`.  Make sure the new IP appears.

A display setting of 1280x800 is more tolerable

The clipboard wont work for some (any) reason

## Install VNC

Download/install TightVNC using the default settings:  https://www.tightvnc.com

Point VNC client at: vnc://blueiris.asyla.org

## Install [BlueIris](https://blueirissoftware.com)

Download/run the latest software: https://blueirissoftware.com/blueiris.exe
