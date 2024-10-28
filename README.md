# Void Linux VPS Installer

Script for replacing existing Linux system with Void Linux on VPS servers.

Tested on VDSina.com: Debian 12 and Ubuntu 24.04
[screenshot](https://github.com/Jipok/void-infect/raw/refs/heads/master/screenshot.png)

## Prerequisites
- Root access
- SSH keys in `/root/.ssh/authorized_keys` 
- `/dev/vda` as main disk
- x86_64 architecture

## Usage
```bash
wget https://github.com/Jipok/void-infect/raw/refs/heads/master/void-infect.sh
chmod +x void-infect.sh
./void-infect.sh
```

The script will:
1. Download Void Linux rootfs
2. Configure minimal system
3. Replace existing OS
4. Reboot into Void Linux

## Features
- Preserves SSH access (key auth only)
- Configures network automatically  
- Installs essential packages
- Uses [doas](https://github.com/Duncaen/OpenDoas) instead of sudo
- Sets up [Cute-bash](https://github.com/Jipok/Cute-bash)

## License
MIT
