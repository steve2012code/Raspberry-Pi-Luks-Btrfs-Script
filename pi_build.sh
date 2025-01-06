#! /bin/bash

# Bash script to set-up a Raspberry Pi with a BTRFS file system, optionally LUKS encryption, Snapper snapshot management and a number of base packages
# Script takes 4 files as input:
#   1. The image file (.img) must be made for the Raspberry Pi
#   2. brtfs-fstab file - Defines the required BTRFS Sub Volumes.  Only line containing "btrfs" will be read.  Will be used to augment the fstab file provided with the image
#   3. user-data file -   The official Raspberry imagers creates a file called user-data in /boot.  On first boot this is used to configure the Pi.  The file format and 
#                         capability appears to comply with the cloud-init format, see link below.
#   4. secrets file -     Used to hold sensitive date that can be substituted into the user-data and / or brtfs-fstab file.  The format is:
#                            [secret_name][delimiter][secret_value]
#                         Where secret_name matches text in user-data and /or fstab file which is to be substituted.  Make sure it doesn't match anything else
#                         The delimiter is taken from the first line of this file which does not begin with #.  Any text up to "#delimiter" is used
#                         as the delimiter, including any spaces.  Make sure the delimiter doesn't match any string in secret_name or secret_value
#                         The presence of a luks_passphase secret_name will enable encryption.  For example:
#                            luks_passphrase : test123
#                         The luks_passphrase secret_name must be called "luks_passphrase".  All other secret_names are user configurable
#                         If there is no line containing "luks_passphrase", the disk will not be encrypted.
# Additionally there are the following flags:
#   -d / --debug -        Just "set -x" to show debug detail
#   -n / --no-interact    If this is present, the script will use the first non-mounted disk as the destination.  Use with caution!
#                         If this isn't present, the script will prompt for confirmation / alternative destintation

# Useful references:
#   https://cloudinit.readthedocs.io/en/latest/index.html - Used for the user-data file
#   https://wiki.archlinux.org/title/Snapper# - Used for the BTRFS and Snapper set-up
#   https://github.com/fullopsec/Dropbear - Used to configure dropbear to allow a remote machine* to provide the luks passphrase
#      *Note the script does not configure a static IP address

# Note, this has only been tested with:
#   Raspberry Pi 5 with NVME PCI connected storage as the destination disk
#   Ubuntu 24.04 server image** for Raspberry Pi as the destination OS
#   This script running on the same Raspberry Pi 5, booted from a SD card with Raspberry Pi Desktop OS, created using the official Raspbery Pi imager.
#      **This image uses the label "writeable" for the root partition.  This script relies on this label!  ToDo - Update to be more flexible.

# Please note that the script doesn't fail elegantly.  If it breaks for any reason, temporary mounts and files will not be deleted.  All temporary files
# and folders are created in the /tmp directory, so a reboot will tidy everything up.


# Script must be run as root
if [ $(id -u) -ne 0 ]
   then echo Please run this script as root or using sudo!
   exit
fi

set -e

usage="$(basename "$0")
Script to build a Raspberry Pi with LUKS encryption and BTRFS file system
Takes 3 files as input:
1. image-file (.img file, must be made for Raspberry Pi)
2. user-data file (Defines base configuration and initial set-up)
3. secrets-file (Includes sensitive information)
    -h, --help                  Show this help text
    -d, --debug                 Debug mode, lots of output
    -n, --no-interact           No user interaction 
    -i, --image-file            Relative path to .img file
    -b, --btrfs-fstab-file      Relative path to btrfs_fstab file
    -u, --user-data-file        Relative path to user-date file
    -s, --secrets-file          Relative path to secrets file"

VALID_ARGS=$(getopt -o hdni:b:u:s: --long help,debug,no-interact,image-file:,btrfs-fstab-file:,user-data-file:,secrets-file: -- "$@")
if [[ $? -ne 0 ]]; then
    echo "$usage"  >&2
    exit 1;
fi

# Defaults
debug_mode=false
no_interact=false
image_file=""
btrfs_fstab=""
user_data_file=""
secrets_file=""

eval set -- "$VALID_ARGS"
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) echo "$usage"; exit 1;;
    -d | --debug) debug_mode=true;;
    -n | --no-interact) no_interact=true;;
    -i | --image-file) image_file=$2; shift;;
    -b | --btrfs-fstab-file) btrfs_fstab=$2; shift;;
    -u | --user-data-file) user_data_file=$2; shift;;
    -s | --secrets-file) secrets_file=$2; shift;;
    (--) shift; break;;
    (-*) echo "$0: Error - unrecognised option $1" 1>&2; echo "$usage"; exit 1;;
    (*) echo "$0: Error - unregonised input $1" 1>&2; echo "$usage"; exit 1;;
  esac
  #sleep 1
  shift
done

#Debug mode output
if $debug_mode; then set -x; fi

# Input argument validation
if [[ $image_file == "" ]]; then
    echo "No image-file provided"
    echo "$usage"
    exit;
fi

if [[ ! -f $image_file ]]; then
    echo "image file: "$image_file" does not exist"
    exit;
fi

if [[ $btrfs_fstab == "" ]]; then
    echo "No btrfs_fstab provided"
    echo "$usage"
    exit;
fi

if [[ ! -f $btrfs_fstab ]]; then
    echo "btrfs_fstab file: "$btrfs_fstab" does not exist"
    exit;
fi

if [[ $user_data_file == "" ]]; then
    echo "No user-data-file provided"
    echo "$usage"
    exit;
fi

if [[ ! -f $user_data_file ]]; then
    echo "user_data_file: "$user_data_file" does not exist"
    exit;
fi

if [[ $secrets_file == "" ]]; then
    echo "No secrets-file provided"
    echo "$usage"
    exit;
fi

if [[ ! -f $secrets_file ]]; then
    echo "secrets_file: "$secrets_file" does not exist"
    exit;
fi

# Check BTRFS is installed
dpkg -s btrfs-progs > /dev/null
if [[ $? != 0 ]]; then
    echo "BTRFS needs to be installed - sudo apt install btrfs-progs"
    exit
fi

# Check cryptsetup is installed
dpkg -s cryptsetup > /dev/null
if [[ $? != 0 ]]; then
    echo "cryptsetup needs to be installed - sudo apt install cryptsetup"
    exit
fi

# Identify disk with no mounted partitions
IFS=$'\n'
for line in $(lsblk --noheadings --raw -o name,type | grep disk); do
    disk=$(echo $line | awk -F ' ' '{ print $1 }')
    # Check is disk has any mounted partitons, if not use it
    if [[ ! $(lsblk --noheadings --raw -o name,type,mountpoint | grep part) =~ $disk ]]; then
        disk_path="/dev/"$disk
        break
    fi
done

disk_path="/dev/"$disk

# Check with the used if this is the disk to be used
if ! $no_interact; then
    while true; do
        read -p "The destination disk is: "$disk_path". Is this correct? (Yes / No / Cancel):" response
        case "${response,,}" in
            (yes)
                break
                ;;
            (no)
                while true; do
                    read -p "Please enter the destination disk path: " disk_path
                    # Check if entered disk path is exists as a disk path
                    if lsblk --noheadings --raw -o path,type,mountpoint | grep disk | grep -w -q $disk_path; then
                        disk=$(echo $disk_path | awk -F '/' '{ print $3 }')
                        # Check if entered disk path has any mounted partitions, if not use it
                        if [[ ! $(lsblk --noheadings --raw -o name,type,mountpoint | grep part) =~ $disk ]]; then
                            echo "The destination disk path exists and isn't mounted, so proceeding."
                            echo
                            break
                        else
                            echo "The destination disk path exists, but is it mounted so can't proceed."
                            echo
                        fi
                    else
                        echo "The destination disk path does not exist" 
                        echo
                    fi
                done
                break
                ;;
            (cancel)
                exit
                ;;
            (*)
                echo "Invalid input. Please enter y, n, or c."
                ;;
        esac
    done
fi

echo "Writing "$image_file" to "$disk_path" ..."

# Delete any existing file system and re-read partition table
wipefs $disk_path
partprobe $disk_path

# Now write the image file to the disk
dd if="$image_file" of="$disk_path" status=progress
sleep 10  # A delay seems to be needed for the partition labels to register
echo

# Derive the boot and root partiton paths.  Note this depends on partition labels
boot_partition_path=$(lsblk --noheadings --raw -o path,type,mountpoint,label | grep $disk_path | grep part | grep boot | awk -F ' ' '{ print $1 }')
root_partition_name=$(lsblk --noheadings --raw -o name,type,mountpoint,label | grep $disk | grep part | grep writable | awk -F ' ' '{ print $1 }')
root_partition_path=$(lsblk --noheadings --raw -o path,type,mountpoint,label | grep $disk_path | grep part | grep writable | awk -F ' ' '{ print $1 }')

# Valid that the boot partition path looks valid, mitigates against occasional errors
if [[ $boot_partition_path == "" || ! $boot_partition_path =~ $disk_path ]]; then
    echo "Error determining the boot partition path, so exiting."
    exit
fi

# Valid that the root partition path looks valid, mitigates against occasional errors
if [[ $root_partition_path == "" || ! $root_partition_path =~ $disk_path ]]; then
    echo "Error determining the boot partition path, so exiting."
    exit
fi

echo "The destination boot partition is: "$boot_partition_path
echo "The destination root partition is: "$root_partition_path
echo

# Read secrets from provided secrets file into an array
IFS=$'\n'
index=0
for line in $(cat $secrets_file); do
    if [[ ! "${line:0:1}" == "#" ]]; then
        if [[ $line =~ "delimiter" ]]; then
            delimiter=$(echo $line | awk -F '#' '{ print $1 }')
        else
            secrets[index]=$(echo $line)
            index=$(($index+1))
        fi
    fi
done

# Create temporary user-data file
cp $user_data_file /tmp/.user-data

luks_passphrase=""
# Substitute secrets into temporary user-name file and assign luks_passphrase to a variable if it exists
for secret in "${secrets[@]}"; do
    secret_name=$(echo $secret | awk -F $delimiter '{ print $1 }')
    secret_value=$(echo $secret | awk -F $delimiter '{ print $2 }')
    if [[ $secret_name == "luks_passphrase" ]] ; then
        luks_passphrase=$secret_value
    else
        sed -i -e 's|'"$secret_name"'|'"$secret_value"'|g' /tmp/.user-data 
    fi
done 

# Create temporary fstab file
cp $btrfs_fstab /tmp/.btrfs_fstab

# Substitute secrets into temporary fstab file
for secret in "${secrets[@]}"; do
    secret_name=$(echo $secret | awk -F $delimiter '{ print $1 }')
    secret_value=$(echo $secret | awk -F $delimiter '{ print $2 }')
    sed -i -e 's|'"$secret_name"'|'"$secret_value"'|g' /tmp/.btrfs_fstab
done 

# Create temporary boot directory for mounting
mkdir -p /tmp/boot
#  Create temporary root directory for mounting
mkdir -p /tmp/old_root
#  Create temporary directory for transfer files from and to the root directory
mkdir -p /tmp/temp_root_store

# Mount boot diectory in temporary directory
mount -v $boot_partition_path /tmp/boot
# Mount root diectory in temporary directory
mount -v $root_partition_path /tmp/old_root
# Copy contents from root directory to temporary store
echo "Copying contents from root directory..."
rsync -ar --stats /tmp/old_root/ /tmp/temp_root_store/
echo
# Unmount temporary root directory
umount -v /tmp/old_root
rm -rf /tmp/old_root

# Resize root partition to fill the disk.  (Cloud-init seems to fail to do this with encrypted disks)
echo "Resizing root partition"
echo
root_partition_id=$(parted /dev/nvme0n1 p | grep ext4 | awk -F ' ' '{ print $1 }')
parted $disk_path resizepart $root_partition_id 100%

# Encrypt partition (if needed),create file system and mount it
mkdir -p /tmp/new_root
if [[ $luks_passphrase == "" ]]; then
    echo "No encryption required"
    echo
    mkfs.btrfs -f -s 4K -n 4K -L writable $root_partition_path
    mount -v $root_partition_path /tmp/new_root
else
    echo "Root partition will be encryped"
    echo
    encrypted_root_partition_name=$root_partition_name"_crypt"
    encrypted_root_partition_path="/dev/mapper/"$encrypted_root_partition_name
    echo $luks_passphrase | cryptsetup luksFormat -q --type=luks2 -c aes-xts-plain64 -s 512 --use-urandom $root_partition_path
    echo $luks_passphrase | cryptsetup luksOpen -q $root_partition_path $encrypted_root_partition_name
    mkfs.btrfs -s 4K -n 4K -L writable $encrypted_root_partition_path
    mount -v $encrypted_root_partition_path /tmp/new_root
fi

# Read through the btrfs_fstab and create the required BTRFS subvolumes
IFS=$'\n'
for line in $(cat /tmp/.btrfs_fstab); do
    if [[ ! "${line:0:1}" == "#" ]]; then
        if echo "$line" | grep -q "btrfs"; then
            mount_point=$(echo "$line" | awk -F ' ' '{ print $2 }')
            subvol_name=$(echo "$line" | awk -F ' ' '{ print $4 }' | awk -F 'subvol=' '{ print $2 }')
            btrfs subvolume create /tmp/new_root/$subvol_name
        fi
    fi
done

# Unmount newly created file system 
umount -v /tmp/new_root

# Read through the btrfs_fstab and mount the newly created BTRFS subvolumes
IFS=$'\n'
for line in $(cat /tmp/.btrfs_fstab); do
    if [[ ! "${line:0:1}" == "#" ]]; then
        if echo "$line" | grep -q "btrfs"; then
            mount_point=$(echo "$line" | awk -F ' ' '{ print $2 }')
            subvol_name=$(echo "$line" | awk -F ' ' '{ print $4 }' | awk -F 'subvol=' '{ print $2 }')
            mount_options=$(echo "$line" | awk -F ' ' '{ print $4 }')
            mkdir -p /tmp/new_root/$subvol_name
            if [[ $luks_passphrase == "" ]]; then
                mount -v -o $mount_options $root_partition_path /tmp/new_root/$subvol_name
            else
                mount -v -o $mount_options $encrypted_root_partition_path /tmp/new_root/$subvol_name
            fi
        fi
    fi
done

# List newly created BTRFS subvolumes
btrfs subvolume list /tmp/new_root/@

# Copy contents from temporary store to new created BTRFS subvolumes
echo "Copying contents to root directory..."
rsync -ar --stats /tmp/temp_root_store/ /tmp/new_root/@/
echo

# Copy temporary user-data file to the boot partiton, display contents and then delete
cp  /tmp/.user-data /tmp/boot/user-data
echo "/boot/user-data file contents:"
cat /tmp/boot/user-data
echo
rm  /tmp/.user-data

# Edit the cmdline.txt file in the boot partition to reflect the BTFRS file system and add encryption detail, if needed
sed -i 's|'"ext4"'|'"btrfs rootflags=subvol=@"'|' /tmp/boot/cmdline.txt
if [[ ! $luks_passphrase == "" ]]; then
    sed -i 's|$|'" cryptdevice=""$root_partition_path"":""$encrypted_root_partition_name"'|' /tmp/boot/cmdline.txt
fi
echo "/tmp/boot/cmdline.txt file contents:"
cat /tmp/boot/cmdline.txt
echo

# If the newly partitioned disk is an nvme device, add gen 3 line to config.txt in the boot partition
if [[ $disk_path =~ "nvme" ]]; then 
    sed -i -e '$a'"dtparam=pciex1_gen=3" /tmp/boot/config.txt
    echo "/tmp/boot/config.txt file contents:"
    cat /tmp/boot/config.txt
    echo
fi

# Edit and append the fstab to reflect the BTFRS file system
sed -i 's|'"LABEL=writable"'|'"#LABEL=writeable"'|' /tmp/new_root/@/etc/fstab
IFS=$'\n'
for line in $(cat /tmp/.btrfs_fstab); do
    if [[ ! "${line:0:1}" == "#" ]]; then
        if echo "$line" | grep -q "btrfs"; then
           sed -i -e '$a'"$line" /tmp/new_root/@/etc/fstab
        fi
    fi
done
echo "/tmp/new_root/@/etc/fstab file contents:"
cat /tmp/new_root/@/etc/fstab
echo

# Edit the crypttab file to add encryption detail, if needed
if [[ ! $luks_passphrase == "" ]]; then
    sed -i -e '$a'"$encrypted_root_partition_name"" ""$root_partition_path"" none luks" /tmp/new_root/@/etc/crypttab
fi
echo "/tmp/new_root/@/etc/crypttab file contents:"
cat /tmp/new_root/@/etc/crypttab
echo

# Unmount BTFRS subvolumes
umount -v /tmp/boot
IFS=$'\n'
for line in $(cat /tmp/.btrfs_fstab); do
    #echo "$line"
    #echo "${line:0:1}"
    if [[ ! "${line:0:1}" == "#" ]]; then
        if echo "$line" | grep -q "btrfs"; then
           subvol_name=$(echo "$line" | awk -F ' ' '{ print $4 }' | awk -F 'subvol=' '{ print $2 }')
           umount -v /tmp/new_root/$subvol_name
           rm -rf /tmp/new_root/$subvol_name
        fi
    fi
done

rm /tmp/.btrfs_fstab
rm -rf /tmp/temp_new_root

echo
if [[ $luks_passphrase == "" ]]; then
    echo "Completed setting up "$disk". Now shutdown and boot from "$disk"."
else
    echo "Completed setting up "$disk". Now:"
    echo "1.  Shutdown and boot from "$disk"."
    echo "2.  Wait for initramfs prompt (takes a while), then enter \"cryptsetup luksOpen /dev/nvme0n1p2 nvme0n1p2_crypt\""
    echo "3.  Enter luks passphrase and wait for prompt"
    echo "4.  Enter \"btrfs device scan\" and then \"exit\""
    echo "5.  Boot and set-up will then continue"
    echo "6.  Subsequent reboots will prompt for the luks passphrase"
fi

# Turn off debugging if necessary
set +x
if $debug_mode; then set +x; fi

exit 0
