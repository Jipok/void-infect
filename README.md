# Void Linux VPS Installer

Script for replacing existing Linux system with Void Linux on VPS servers.

Tested on VDSina.com: Debian 12 and Ubuntu 24.04
![1](https://github.com/user-attachments/assets/8c52be10-cdc6-4401-9d5e-e3996882b8a6)

## Prerequisites
- Root access
- SSH keys in `/root/.ssh/authorized_keys` 
- `/dev/vda` as main disk
- x86_64 architecture

## Usage
```bash
wget https://raw.githubusercontent.com/Jipok/void-infect/refs/heads/master/void-infect.sh
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
