# Void Linux VPS Installer

Script for replacing existing Linux system with Void Linux on VPS servers. Tested on Debian 12 (VDSina.com).

## Prerequisites
- Root access
- SSH keys in `/root/.ssh/authorized_keys` 
- `/dev/vda` as main disk
- x86_64 architecture

## Usage
```bash
wget https://raw.githubusercontent.com/Jipok/void-infect/main/void-infect.sh
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

## Troubleshooting
Check `/tmp/void-infect.log` for errors

## License
MIT
