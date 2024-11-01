# Void Linux VPS Installer

Script for replacing existing Linux system with Void Linux on VPS servers.

Tested on VDSina.com: Debian, Ubuntu and CentOS

![изображение](https://github.com/user-attachments/assets/e35b88d0-cb3a-4263-9dac-efe0a513f3b7)


## Prerequisites
- Root access
- SSH keys in `/root/.ssh/authorized_keys` 
- `/dev/vda` as main disk

## Usage
```bash
wget https://raw.githubusercontent.com/Jipok/void-infect/refs/heads/master/void-infect.sh
chmod +x void-infect.sh
./void-infect.sh
```

The script automatically:
- Downloads and configures Void Linux rootfs
- Preserves SSH keys and network configuration
- Installs essential packages and [Cute-bash](https://github.com/Jipok/Cute-bash)
- Replaces existing OS and reboots

No manual intervention required. Just run and wait for the reboot.

## License
MIT
