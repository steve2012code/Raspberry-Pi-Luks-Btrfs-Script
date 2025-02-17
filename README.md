# Raspberry Pi 5, BTRFS LUKS imager script

## Overview
Bash script to set-up a Raspberry Pi with a BTRFS file system, optionally LUKS encryption, Snapper snapshot management and a number of base packages 

Script takes 4 files as input: 

1. The image file (.img) must be made for the Raspberry Pi 
2. brtfs-fstab file - Defines the required BTRFS Sub Volumes.  Only line containing "btrfs" will be read.  Will be used to augment the fstab file provided with the image.  Any secrets to be substituted need to be in the format: `{{secret_name}}` (with secret_name defined in the secrets file). 
3. user-data file -   The official Raspberry imagers creates a file called user-data in /boot.  On first boot this is used to configure the Pi.  The file format and capability appears to comply with the cloud-init format, see link below. Any secrets to be substituted need to be in the format: `{{secret_name}}` (with secret_name defined in the secrets file) 
4. secrets file -     Used to hold sensitive date that can be substituted into the user-data and or brtfs-fstab file.  The format is yaml.  Multi line secrets (such as Private Keys are supported).  The presence of a luks_passphase secret_name will enable encryption, for example: `luks_passphrase : test123`.  The luks_passphrase secret_name must be called `luks_passphrase`.  All other secret_names are user configurable.  If there is no line containing "luks_passphrase", the disk will not be encrypted. 

Additionally there are the following flags: 
-d / --debug -        Just "set -x" to show debug detail 
-n / --no-interact    If this is present, the script will use the first non-mounted disk as the destination.  Use with caution! 
If this isn't present, the script will prompt for confirmation or an alternative destintation 

## Example usage 
Display help information 

```
sudo ./pi_build.sh -h

pi_build.sh
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
    -s, --secrets-file          Relative path to secrets file
```

Example command to set-up an encrypted environment.  See [Example_Configs](Example_Configs) for formats and examples.
```
sudo ./pi_build.sh -i ./image/ubuntu-24.04.1-preinstalled-server-arm64+raspi.img -b ./Example_Configs/fstab -u ./Example_Configs/user-data -s ./Example_Configs.secrets_luks.yaml
```

## Useful references
1. https://cloudinit.readthedocs.io/en/latest/index.html - Used for the user-data file
2. https://wiki.archlinux.org/title/Snapper- Used for the BTRFS and Snapper set-up
3. https://github.com/fullopsec/Dropbear - Used to configure dropbear to allow a remote machine to provide the luks passphrase.  Note the script does not configure a static IP address

## Environment
Note, this has only been tested with:
   Raspberry Pi 5 with NVME PCI connected storage as the destination disk
   [Ubuntu 24.04 server image](https://cdimage.ubuntu.com/releases/24.04.1/release/ubuntu-24.04.1-preinstalled-server-arm64+raspi.img.xz) for Raspberry Pi as the destination OS
   This script running on the same Raspberry Pi 5, booted from a SD card with Raspberry Pi Desktop OS, created using the official Raspbery Pi imager. \
      Note - This image uses the label "writeable" for the root partition.  This script relies on this label!  ToDo - Update to be more flexible.

## Caveats
Please note that the script doesn't fail elegantly.  If it breaks for any reason, temporary mounts and files will not be deleted.  All temporary files
and folders are created in the /tmp directory, so a reboot will tidy everything up.

## Dependencies
This scripts requires the btrfs-progs, cryptsetup and yq packages to be installed.

This script has not been extensively tested, use at your own risk
