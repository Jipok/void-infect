# Void Linux VPS Installer

Script for replacing existing Linux system with Void Linux on VPS servers.

Tested with Debian, Ubuntu and CentOS

Tested on VDSina.com, FirstByte.pro

![screenshot](https://github.com/user-attachments/assets/142057c6-4067-41c6-8ca5-d04720fd6a95)

## Prerequisites
- Root access
- SSH keys in `/root/.ssh/authorized_keys`
- Installation time: ~2 minutes

## Usage
```bash
wget https://raw.githubusercontent.com/Jipok/void-infect/refs/heads/master/void-infect.sh
chmod +x void-infect.sh
./void-infect.sh
```

The script automatically:
- Downloads and configures Void Linux rootfs
- Installs essential packages and [Cute-bash](https://github.com/Jipok/Cute-bash)
- Replaces existing OS and reboots

No manual intervention required. Just run and wait for the reboot.

## Home Server Installation Script

For installing Void Linux on a physical home server, use the alternative script:

```bash
wget https://raw.githubusercontent.com/Jipok/void-infect/refs/heads/master/void-install.sh
chmod +x void-install.sh
nano void-install.sh        # Change settings in file header
./void-install.sh /dev/sdX  # Replace with your target disk
```
**Note: This script must be run from a LiveUSB environment or when installing to a secondary disk that's not currently hosting the running system.**