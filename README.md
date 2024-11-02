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

## License
MIT
