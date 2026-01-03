#!/bin/bash

# Exit on error
set -e

# Configuration
VMID=2000
NAME="d03"
IP="10.0.0.63/24"
GW="10.0.0.1"
DNS="10.0.0.10,10.0.0.11"
SEARCHDOMAIN="asyla.org"
USER="docker"
PUB_SSHKEY=~/.ssh/docker_rsa.pub
ST_VOL="nas-data1-vm"
DEBIAN="debian-12-generic-amd64.qcow2"
DEBIANURL="https://cloud.debian.org/images/cloud/bookworm/latest/$DEBIAN"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if libguestfs-tools is installed
check_libguestfs() {
    if ! command_exists virt-customize; then
        echo "Installing libguestfs-tools..."
        sudo apt-get update
        sudo apt-get install -y libguestfs-tools
    fi
}

# Function to download and prepare the Debian image
prepare_image() {
    echo "Downloading and preparing Debian image..."
    cd ~
    rm -f debian-12*.qcow2
    wget $DEBIANURL

    # Install qemu client and configure image
    virt-customize -a $DEBIAN --install qemu-guest-agent
    virt-customize -a $DEBIAN --timezone "America/Chicago"
    
    # Kubernetes settings
    virt-customize -a $DEBIAN \
        --append-line '/etc/sysctl.d/99-k8s-cni.conf:' \
        --append-line '/etc/sysctl.d/99-k8s-cni.conf:net.bridge.bridge-nf-call-iptables=1' \
        --append-line '/etc/sysctl.d/99-k8s-cni.conf:net.bridge.bridge-nf-call-ip6tables=1'

    # Ensure new machine ID for each clone
    virt-customize -a $DEBIAN --truncate /etc/machine-id

    # Add sid repository
    TEMP_MOUNT=/mnt/temp
    guestunmount $TEMP_MOUNT 2>/dev/null || true
    mkdir -p $TEMP_MOUNT
    guestmount -a ~/$DEBIAN -m /dev/sda1 $TEMP_MOUNT

    cat <<EOF >> $TEMP_MOUNT/etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://http.us.debian.org/debian
Suites: sid
Components: main
EOF

    guestunmount $TEMP_MOUNT
    rmdir $TEMP_MOUNT

    # Install cloud-init
    virt-customize -a ~/$DEBIAN --run-command "apt-get update"
    virt-customize -a ~/$DEBIAN --run-command "apt-get install -y cloud-init"
}

# Function to create and configure the VM
create_vm() {
    echo "Creating and configuring VM..."
    qm destroy $VMID 2>/dev/null || true

    # Create VM
    qm create $VMID \
        --name $NAME \
        --cpu host \
        --machine q35 \
        --memory 25600 \
        --cores 6 \
        --sockets 2 \
        --ostype l26 \
        --numa 1 \
        --onboot 1 \
        --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
        --agent enabled=1,fstrim_cloned_disks=1,type=virtio

    # Import disk
    qm importdisk $VMID $DEBIAN $ST_VOL -format qcow2
    qm set $VMID \
        --scsihw virtio-scsi-pci \
        --scsi0 $ST_VOL:$VMID/vm-$VMID-disk-0.qcow2

    # Resize disk
    qm resize $VMID scsi0 64G

    # Configure boot
    qm set $VMID \
        --ide2 $ST_VOL:cloudinit \
        --boot c \
        --bootdisk scsi0 \
        --vga serial0 \
        --serial0 socket

    # Configure user and networking
    qm set $VMID \
        --ciuser $USER \
        --sshkey $PUB_SSHKEY \
        --ipconfig0 ip=$IP,gw=$GW \
        --nameserver $DNS \
        --searchdomain $SEARCHDOMAIN
}

# Function to wait for VM to be ready
wait_for_vm() {
    echo "Waiting for VM to be ready..."
    while ! ping -c 1 -W 1 $IP >/dev/null 2>&1; do
        sleep 5
    done
}

# Function to configure the VM
configure_vm() {
    echo "Configuring VM..."
    # Copy setup scripts
    scp -r setup/ $USER@$IP:~/setup/
    scp update.sh update_scripts.sh $USER@$IP:~/

    # Execute setup scripts
    ssh $USER@$IP "chmod +x ~/setup/*.sh ~/update.sh ~/update_scripts.sh"
    ssh $USER@$IP "~/setup/systemConfig.sh"
    ssh $USER@$IP "~/setup/docker.sh"
    ssh $USER@$IP "~/setup/smb.sh"
    ssh $USER@$IP "~/setup/nfs.sh"
    ssh $USER@$IP "~/setup/iscsi.sh"
    ssh $USER@$IP "~/update.sh"
}

# Main execution
echo "Starting VM creation process..."

# Check and install required tools
check_libguestfs

# Prepare the image
prepare_image

# Create and configure the VM
create_vm

# Start the VM
echo "Starting VM..."
qm start $VMID

# Wait for VM to be ready
wait_for_vm

# Configure the VM
configure_vm

echo "VM creation and configuration complete!"
echo "You can now connect to the VM using: ssh $USER@$IP" 