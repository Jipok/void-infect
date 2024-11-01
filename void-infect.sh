#!//usr/bin/env bash
# void-infect: Install Void linux over the existing OS on VPS
# Inspired by nixos-infect (https://github.com/elitak/nixos-infect)
set -e  # Exit on any error


VOID_LINK="https://repo-default.voidlinux.org/live/current/void-x86_64-ROOTFS-20240314.tar.xz"
VOID_HASH="9087a3e23367347a717f0bb11c2541e6abe93054a146cc3aa95545d32379b8a1"
ADD_LOCALE="ru_RU.UTF-8" # Optional
ADD_PKG="fuzzypkg vsv tmux dte nano gotop fd ncdu git tree neofetch"
SET_HOSTNAME=void-vps


# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[+]${NC} $1"
}

error() {
    echo -e "${RED}[!]${NC} $1"
    exit 1
}

try() {
    local log_file=$(mktemp)
    
    if ! eval "$@" &> "$log_file"; then
        cat "$log_file"
        error "Failed: $@"
    fi
    rm -f "$log_file"
}

POINT_OF_NO_RETURN=false
cleanup() {
    if [ "$POINT_OF_NO_RETURN" = false ]; then
        echo -e "

╔════════════════════════════════════════════════════════════════════╗
║                        INSTALLATION ABORTED                        ║
╠════════════════════════════════════════════════════════════════════╣
║ ${GREEN}The system has NOT been broken.  ${NC}                                  ║
║ You can safely:                                                    ║
║   1. rm -rf /void                                                  ║
║   2. Reboot the system                                             ║
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
    fi
    bash
    exit 1
}

trap cleanup ERR INT TERM


###############################################################################

# First stage, before chroot

if [ -z $VOID_INFECT_STAGE_2 ]; then
    [[ $(id -u) == 0 ]] || error "This script must be run as root"
    [ -s /root/.ssh/authorized_keys ] || error "At least one SSH key required in root's authorized_keys"
    [[ -e /dev/vda ]] || error "Disk /dev/vda not found"
    [[ -d /void ]] && error "Remove /void before start"

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
    try cd /void
    try mkdir -p {proc,sys,dev,run,oldroot}

    log "Downloading Void Linux rootfs..."
    try curl -fL "$VOID_LINK" -o "/void/rootfs.tar.xz"

    log "Verifying SHA256 checksum..."
    CALCULATED_HASH=$(sha256sum "/void/rootfs.tar.xz" | cut -d' ' -f1)
    if [ "$CALCULATED_HASH" != "$VOID_HASH" ]; then
        error "SHA256 checksum verification failed!"
    fi

    log "Extracting rootfs..."
    try tar xf "/void/rootfs.tar.xz" -C "/void"
    try rm "/void/rootfs.tar.xz"

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

    # TODO  No pstree on clean debian 10
    #
    # log "Killing all other processes..."
    # local ssh_pids=$(pstree -p $$ | grep -o '([0-9]\+)' | tr -d '()')
    # for pid in $(ps -A -o pid=); do
    #     if [ "$pid" -ne 1 ] && \
    #         ! echo "$ssh_pids" | grep -q "^$pid$" && \
    #         [ ! -d "/proc/$pid/task" ]; then
    #         kill -9 "$pid" 2>/dev/null || true
    #     fi
    # done

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

log "Installing base system..."
# Don't use `base-system` because it contains heavy and useless WiFi drivers
try xbps-install -y base-minimal linux
# Useful packages from base-system
try xbps-install -y man-pages mdocml ncurses iproute2 iputils traceroute ethtool file kmod

log "Installing necessary packages..."
# Utils used by scripts
try xbps-install -y bind-utils psmisc parallel less jq unzip bc git
# We need it
try xbps-install -y grub wget curl openssh bash

log "Installing useful packages..."
try xbps-install -y $ADD_PKG

log "Installing simple cron..."
try xbps-install -y scron
ln -sf /etc/sv/crond /etc/runit/runsvdir/default/

log "Installing ufw..."
try xbps-install -y ufw
ln -sf /etc/sv/ufw /etc/runit/runsvdir/default/
sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
echo "ufw allow ssh #VOID-INFECT-STAGE-3" >> /etc/rc.local 

log "Disabling unused services (agetty, udev)..."
rm /etc/runit/runsvdir/default/agetty*
rm /etc/runit/runsvdir/default/udevd

log "Setting up bash configuration..."
try wget https://raw.githubusercontent.com/Jipok/Cute-bash/master/.bashrc -O "/etc/bash/bashrc.d/cute-bash.sh"
try wget "https://raw.githubusercontent.com/trapd00r/LS_COLORS/master/LS_COLORS" -O "/etc/bash/ls_colors"
try wget "https://raw.githubusercontent.com/cykerway/complete-alias/master/complete_alias" -O "/etc/bash/complete_alias"
try wget "https://raw.githubusercontent.com/scop/bash-completion/2.11/bash_completion" -O "/etc/bash/bash-completion-2.11"
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
[ -n "$ipv6_addr" ] && echo         "ip -6 addr add $ipv6_addr dev eth0"                 >> /etc/rc.local 
[ -n "$ipv6_gateway" ] && echo      "ip -6 route add default via $ipv6_gateway"          >> /etc/rc.local 
[ -n "$ipv6_gateway" ] || echo      "# Enable IPv6 autoconfig"                           >> /etc/rc.local 
[ -n "$ipv6_gateway" ] || echo      "echo 1 > /proc/sys/net/ipv6/conf/eth0/accept_ra"    >> /etc/rc.local 
echo                                ""                                                   >> /etc/rc.local 
echo                                "rm -rf /void #VOID-INFECT-STAGE-3"                  >> /etc/rc.local 
echo                                "sed -i '/#VOID-INFECT-STAGE-3/d' /etc/rc.local "    >> /etc/rc.local 

log "Configuring SSH..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
ln -sf /etc/sv/sshd /etc/runit/runsvdir/default/

# log "Setting root password..."
# echo "root:voidlinux" | chpasswd

log "Disabling root password login..."
try passwd -l root

# Sudo not present in base-minimal 
#
# log "Removing sudo..."
# echo "ignorepkg=sudo" > /etc/xbps.d/no-sudo.conf
# try xbps-install -y opendoas
# try xbps-remove -y sudo

log "Configuring fstab..."
# TODO autodetect
echo "/dev/vda1 / ext4 defaults 0 1" > /etc/fstab

###############################################################################

POINT_OF_NO_RETURN=true

log "Installing bootloader..."
try grub-install /dev/vda
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
    --exclude='./tmp' \
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
║ System has been successfully reinstalled!                          ║
║                                                                    ║
║ ATTENTION: SSH host keys have been regenerated.                    ║
║ You will receive a warning about changed host key                  ║
║ on your next SSH connection.                                       ║
║                                                                    ║
║ To avoid connection errors, run this command                       ║
║ on your local machine:                                             ║
║                                                                    ║
║   ${GREEN}ssh-keygen -R ${FORMATTED_IP}${NC}                                    ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
"

/sbin/reboot -f