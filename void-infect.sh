#!/usr/bin/env bash
# void-infect: Install Void linux over the existing OS on VPS
# Inspired by nixos-infect (https://github.com/elitak/nixos-infect)
set -e  # Exit on any error


VOID_LINK="https://repo-default.voidlinux.org/live/current/void-x86_64-ROOTFS-20250202.tar.xz"
VOID_HASH="3f48e6673ac5907a897d913c97eb96edbfb230162731b4016562c51b3b8f1876"

ADD_LOCALE="ru_RU.UTF-8" # Optional
ADD_PKG="fuzzypkg vsv tmux dte nano gotop fd ncdu git tree neofetch"
SET_HOSTNAME=void-vps


# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[+]${NC} $1"
}

error() {
    echo -e "${RED}[!]${NC} $1"
    handle_error
}

try() {
    local log_file=$(mktemp)
    
    if ! eval "$@" &> "$log_file"; then
        echo -e "${RED}[!]${NC} Failed: $*"
        cat "$log_file"
        handle_error
    fi
    rm -f "$log_file"
}

export POINT_OF_NO_RETURN=false
export SCRIPT_STARTED=false
handle_error() {
    [ "$SCRIPT_STARTED" = false ] && exit 1
    if [ "$POINT_OF_NO_RETURN" = false ]; then
        echo -e "

╔════════════════════════════════════════════════════════════════════╗
║                        INSTALLATION ABORTED                        ║
╠════════════════════════════════════════════════════════════════════╣
║ ${GREEN}The system has NOT been broken.  ${NC}                                  ║
║ You can safely:                                                    ║
║   1. Reboot the system                                             ║
║   2. rm -rf /void                                                  ║
╚════════════════════════════════════════════════════════════════════╝
"
    else
        echo -e "

╔════════════════════════════════════════════════════════════════════╗
║                           ${RED}CRITICAL ERROR${NC}                           ║
╠════════════════════════════════════════════════════════════════════╣
║ Installation failed during system replacement.                     ║
║                                                                    ║
║ You can:                                                           ║
║   1. Try to complete Void installation manually:                   ║
║      - You are now in chroot environment                           ║
║      - Check error message above                                   ║
║      - Continue with remaining installation steps                  ║
║                                                                    ║
║   2. If unsure, just reinstall your system using VPS panel         ║
╚════════════════════════════════════════════════════════════════════╝
"
        bash
    fi
    exit 1
}

trap handle_error ERR INT TERM

###############################################################################

# First stage, before chroot

if [ -z $VOID_INFECT_STAGE_2 ]; then
    [[ $(id -u) == 0 ]] || error "This script must be run as root"
    [ -s /root/.ssh/authorized_keys ] || error "At least one SSH key required in root's authorized_keys"
    [[ -d /void ]] && error "Remove /void before start"
    command -v findmnt >/dev/null 2>&1 || error "findmnt not found. Install util-linux"
    export SCRIPT_STARTED=true

    echo "
          _______ _________ ______    _________ _        _______  _______  _______ _________
|\     /|(  ___  )\__   __/(  __  \   \__   __/( (    /|(  ____ \(  ____ \(  ____ \\__   __/
| )   ( || (   ) |   ) (   | (  \  )     ) (   |  \  ( || (    \/| (    \/| (    \/   ) (   
| |   | || |   | |   | |   | |   ) |     | |   |   \ | || (__    | (__    | |         | |   
( (   ) )| |   | |   | |   | |   | |     | |   | (\ \) ||  __)   |  __)   | |         | |   
 \ \_/ / | |   | |   | |   | |   ) |     | |   | | \   || (      | (      | |         | |   
  \   /  | (___) |___) (___| (__/  )  ___) (___| )  \  || )      | (____/\| (____/\   | |   
   \_/   (_______)\_______/(______/   \_______/|/    )_)|/       (_______/(_______/   )_(   
"

    log "Creating /void directory..."
    SCRIPT_PATH=$(readlink -f "$0")
    try mkdir -p /void
    try mkdir -p /void/{proc,sys,dev,run,oldroot}

    log "Downloading $(basename "$VOID_LINK" .tar.xz)..."
    if command -v curl >/dev/null 2>&1; then
        try curl -fL "$VOID_LINK" -o "/void/rootfs.tar.xz"
    elif command -v wget >/dev/null 2>&1; then
        try wget -O "/void/rootfs.tar.xz" "$VOID_LINK"
    else
        echo "Error: Neither curl nor wget is available"
        exit 1
    fi

    log "Verifying SHA256 checksum..."
    CALCULATED_HASH=$(sha256sum "/void/rootfs.tar.xz" | cut -d' ' -f1)
    if [ "$CALCULATED_HASH" != "$VOID_HASH" ]; then
        error "SHA256 checksum verification failed!"
    fi

    log "Extracting rootfs..."
    try tar xf "/void/rootfs.tar.xz" -C "/void"
    try rm "/void/rootfs.tar.xz"

    log "Configuring fstab..."
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    ROOT_FS_TYPE=$(findmnt -n -o FSTYPE /)
    export ROOT_DISK=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')
    [[ -e "$ROOT_DISK" ]] || error "Could not determine root disk device"
    [[ -b "$ROOT_DISK" ]] || error "Invalid root disk device: $ROOT_DISK"
    # TODO Is it reely need?
    echo "$ROOT_DEV / $ROOT_FS_TYPE defaults 0 1" >> /void/etc/fstab

    log "Copying essential files..."
    echo "$SET_HOSTNAME" > /void/etc/hostname
    # self
    cp "$SCRIPT_PATH" /void/void-infect.sh
    # ssh
    mkdir -p /void/root/.ssh
    try cp -r /root/.ssh/authorized_keys /void/root/.ssh/
    chmod 700 /void/root/.ssh
    chmod 600 /void/root/.ssh/authorized_keys
    # Extract DNS servers, replace localhost with 1.1.1.1
    grep ^nameserver /etc/resolv.conf | sed -r \
        -e 's/127[0-9.]+/1.1.1.1/' \
        -e 's/::1/1.1.1.1/' > /void/etc/resolv.conf

    log "Stopping non-essential services..."
    systemctl list-units --type=service --state=running | \
        grep '\.service' | \
        cut -d' ' -f1 | \
        grep -vE '(sshd|systemd-journal|systemd-udev)' | \
        xargs -r systemctl stop >> /dev/null

    log "Unmounting all non-essential filesystems..."
    swapoff -a || true
    awk '$2!="/" && $2!="" && $2!="/void" && $2!="/sys" && $2!="/proc" && $2!="/dev" {print $2}' /proc/mounts | sort -r | \
    while read -r mount_point; do
        umount -f -l "$mount_point" 2>/dev/null || true
    done

    log "Mounting necessary filesystems..."
    try mount --bind / /void/oldroot
    try mount --bind /dev /void/dev
    try mount --bind /proc /void/proc
    try mount --bind /sys /void/sys

    log "Entering chroot..."
    env VOID_INFECT_STAGE_2=y chroot /void /void-infect.sh

    exit 0
fi

###############################################################################

# Second stage, inside chroot

log "Updating xbps..."
try xbps-install -Syu xbps

log "Updating packages..."
try xbps-install -Syu

log "Configuring xbps..."
echo 'ignorepkg=linux-firmware-amd
ignorepkg=linux-firmware-intel
ignorepkg=linux-firmware-nvidia
ignorepkg=linux-firmware-network' >> /etc/xbps.d/ignore.conf

log "Installing base system..."
# Don't use `base-system` because it contains heavy and useless WiFi drivers
try xbps-install -y base-minimal linux
# Useful packages from base-system
try xbps-install -y man-pages mdocml ncurses iproute2 iputils traceroute ethtool file kmod

log "Installing necessary packages..."
# Utils used by scripts
try xbps-install -y bind-utils inotify-tools psmisc parallel less jq unzip bc git
# We need it
try xbps-install -y grub wget curl openssh bash-completion

log "Installing useful packages..."
try xbps-install -y $ADD_PKG

log "Installing simple cron..."
try xbps-install -y scron
ln -sf /etc/sv/crond /etc/runit/runsvdir/default/
echo "# * (wildcard), 30 (number), */N (repeat), 1-5 (range), or 1,3,6 (list)
#
# .---------------- minute (0 - 59)
# | .------------- hour (0 - 23)
# | |  .---------- day of month (1 - 31)
# | |  |  .------- month (1 - 12)
# | |  |  |    .-- day of week (0 - 6)
# | |  |  |    |
# m h dom mon dow   command

0 4 * * * run-parts /etc/cron.daily &>> /var/log/cron.daily.log
" > /etc/crontab

log "Installing ufw..."
try xbps-install -y ufw
ln -sf /etc/sv/ufw /etc/runit/runsvdir/default/
sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
echo "ufw allow ssh #VOID-INFECT-STAGE-3" >> /etc/rc.local 

log "Disabling unused services (agetty, udev)..."
xbps-remove -Oo
rm /etc/runit/runsvdir/default/agetty*
rm /etc/runit/runsvdir/default/udevd

log "Setting up bash configuration..."
try wget https://raw.githubusercontent.com/Jipok/Cute-bash/master/.bashrc -O "/etc/bash/bashrc.d/cute-bash.sh"
try wget "https://raw.githubusercontent.com/trapd00r/LS_COLORS/master/LS_COLORS" -O "/etc/bash/ls_colors"
try wget "https://raw.githubusercontent.com/cykerway/complete-alias/master/complete_alias" -O "/etc/bash/complete_alias"
rm "/etc/skel/.bashrc" 2>/dev/null || true
usermod -s /bin/bash root || error "Failed to set bash as default shell"

if [[ ! -z "$ADD_LOCALE" ]]; then
    log "Setting locales..."
    sed -i "s/^# *$ADD_LOCALE/$ADD_LOCALE/" /etc/default/libc-locales
    try xbps-reconfigure -f glibc-locales
fi

log "Configuring network in /etc/rc.local..."
interface=$(ip route show default | head -n1 | awk '{print $5}')
[[ -z "$interface" ]] && interface=$(ip -6 route show default 2>/dev/null | head -n1 | awk '{print $5}')
# 4
ipv4_addr=$(ip addr show dev "$interface" | grep 'inet ' | awk '{print $2}')
ipv4_gateway=$(ip route show default | head -n1 | awk '{print $3}')
# 6
ipv6_addr=$(ip -6 addr show dev "$interface" | grep 'inet6' | grep -v 'fe80' | awk '{print $2}')
ipv6_gateway=$(ip -6 route show default | head -n1 | awk '{print $3}')
#
echo                                ""                                                   >> /etc/rc.local 
echo                                "# From void-infect.sh"                              >> /etc/rc.local 
echo                                "ip link set dev eth0 up"                            >> /etc/rc.local 
[ -n "$ipv4_addr" ] && echo         "ip addr add $ipv4_addr dev eth0"                    >> /etc/rc.local 
[ -n "$ipv4_gateway" ] && echo      "ip route add default via $ipv4_gateway"             >> /etc/rc.local 
[ -n "$ipv6_addr" ] && echo         "ip -6 addr add $ipv6_addr dev eth0"                 >> /etc/rc.local && \
  [ -z "$ipv6_gateway" ] && echo    "echo 1 > /proc/sys/net/ipv6/conf/eth0/accept_ra"    >> /etc/rc.local 
[ -n "$ipv6_gateway" ] && echo      "ip -6 route add default via $ipv6_gateway"          >> /etc/rc.local 
echo                                ""                                                   >> /etc/rc.local 
echo                                "rm -rf /void #VOID-INFECT-STAGE-3"                  >> /etc/rc.local 
echo                                "sed -i '/#VOID-INFECT-STAGE-3/d' /etc/rc.local "    >> /etc/rc.local 

log "Configuring SSH..."
# Secure SSH configuration
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
# Generate only modern Ed25519 key (faster and more secure than RSA)
try 'ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""'
SSH_FP=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
# Prevent generation of legacy keys during service start
cp -r /etc/sv/sshd /etc/runit/runsvdir/default/
sed -i '/ssh-keygen -A/d' /etc/runit/runsvdir/default//sshd/run

log "Disabling root password login..."
try passwd -l root

log "Downloading sysctl configuration..."
try mkdir /etc/sysctl.d
try wget "https://raw.githubusercontent.com/Jipok/void-infect/refs/heads/master/sysctl.conf" -O /etc/sysctl.d/99-default.conf

# Calculate total memory (in MB)
mem_total_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
TOTAL_MEM=$((mem_total_kb / 1024))
# Determine selected memory section based on total memory
if [ "$TOTAL_MEM" -le 1500 ]; then
    SELECTED="MEM_1GB"
elif [ "$TOTAL_MEM" -le 2500 ]; then
    SELECTED="MEM_2GB"
elif [ "$TOTAL_MEM" -le 4500 ]; then
    SELECTED="MEM_3-4GB"
elif [ "$TOTAL_MEM" -le 11000 ]; then
    SELECTED="MEM_5-8GB"
else
    SELECTED="MEM_16+GB"
fi

# Remove the 'MEM_' prefix for pretty logging
SELECTED_PRETTY=${SELECTED#MEM_}
log "Applying sysctl configuration for $SELECTED_PRETTY RAM"

# Remove unselected memory markers from the sysctl configuration
for marker in MEM_1GB MEM_2GB MEM_3-4GB MEM_5-8GB MEM_16+GB; do
    if [ "$marker" != "$SELECTED" ]; then
         sed -i "/# --- BEGIN $marker/,/# --- END $marker/d" /etc/sysctl.d/99-default.conf
    else
         sed -i "/# --- BEGIN $marker/d" /etc/sysctl.d/99-default.conf
         sed -i "/# --- END $marker/d" /etc/sysctl.d/99-default.conf
    fi
done

###############################################################################

export POINT_OF_NO_RETURN=true

log "Installing bootloader..."
if [ -d "/sys/firmware/efi" ]; then
    try xbps-install -y grub-x86_64-efi efibootmgr
    try grub-install --target=x86_64-efi --efi-directory=/boot --removable
else
    try grub-install "$ROOT_DISK"
fi
# Use traditional Linux naming scheme for interfaces
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0 /' /etc/default/grub
# IPv6 support
[ -n "$ipv6_addr" ] && sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=0 /' /etc/default/grub
try update-grub

log "Removing old system..."
cd /oldroot
ls -A | grep -vE '^(dev|proc|sys|mnt|void)$' | xargs rm -rf

log "Copying new system..."
cd /
tar -cf - \
    --exclude='./dev/*' \
    --exclude='./proc/*' \
    --exclude='./sys/*' \
    --exclude='./tmp/*' \
    --exclude='./run/*' \
    --exclude='./media/*' \
    --exclude='./lost+found' \
    --exclude='./oldroot*' \
    --exclude='./void-infect.sh' \
    . | (cd /oldroot && tar xf -)
sync

log "System replacement complete. Rebooting..."

IP_ADDRESS=$(ip route get 1 2>/dev/null | awk '{print $7}' | head -1)
FORMATTED_IP=$(printf "%-15s" "${IP_ADDRESS}")
echo -e "
╔════════════════════════════════════════════════════════════════════╗
║                       IMPORTANT INFORMATION                        ║
╠════════════════════════════════════════════════════════════════════╣
║ You will receive a warning about changed host key                  ║
║ on your next SSH connection.                                       ║
║                                                                    ║
║ To avoid connection errors, run this command                       ║
║ on your local machine:                                             ║
║   ${GREEN}ssh-keygen -R ${FORMATTED_IP}${NC}                                    ║
║                                                                    ║
║ New SSH host key fingerprint:                                      ║
║   ${BLUE}${SSH_FP}${NC}               ║
║                                                                    ║
║ Verify the fingerprint when connecting!                            ║
╚════════════════════════════════════════════════════════════════════╝
"

/sbin/reboot -f