#!/usr/bin/env bash
# This is a script for installing Void on a home server
set -e  # Exit on any error


SET_HOSTNAME="void-server"
ADD_LOCALE="ru_RU.UTF-8"  # Optional locale

SWAP_GB=8            # Swap size in gigabytes; set to 0 for no swap partition
WIFI=true            # If true, install NetworkManager (for WiFi); if false, install dhcpcd (for wired)
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKpjScT3SXKVi36st5dpCTqacF00LJ1lKo4SXaFswC3Y Jipok"

ADD_PKG="fuzzypkg vsv tmux dte nano gotop fd ncdu git tree neofetch"
VOID_LINK="https://repo-default.voidlinux.org/live/current/void-x86_64-ROOTFS-20250202.tar.xz"
VOID_HASH="3f48e6673ac5907a897d913c97eb96edbfb230162731b4016562c51b3b8f1876"



# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${GREEN}[+]${NC} $1"
}

error() {
    echo -e "${RED}[!]${NC} $1"
    handle_error
}

try() {
    local log_file
    log_file=$(mktemp)
    
    if ! eval "$@" &> "$log_file"; then
        echo -e "${RED}[!]${NC} Failed: $*"
        cat "$log_file"
        handle_error
    fi
    rm -f "$log_file"
}

export SCRIPT_STARTED=false
handle_error() {
    [ "$SCRIPT_STARTED" = false ] && exit 1
    if [ -z "$VOID_INSTALL_STAGE_2" ]; then
        echo -e "

╔════════════════════════════════════════════════════════════════════╗
║                        INSTALLATION ABORTED                        ║
╠════════════════════════════════════════════════════════════════════╣
║ ${GREEN}Target disk operations failed but your LiveUSB is unaffected.${NC}      ║
║ You can safely:                                                    ║
║   1. Fix the reported issue                                        ║
║   2. Retry the installation script                                 ║
║   3. Unmount any mounted partitions if needed                      ║
╚════════════════════════════════════════════════════════════════════╝
"
    else
        echo -e "

╔════════════════════════════════════════════════════════════════════╗
║                           ${RED}CRITICAL ERROR${NC}                           ║
╠════════════════════════════════════════════════════════════════════╣
║ Installation failed inside chroot environment.                     ║
║                                                                    ║
║ You can:                                                           ║
║   1. Try to complete Void installation manually:                   ║
║      - Check error message above                                   ║
║      - Continue with remaining installation steps                  ║
║                                                                    ║
║   2. Type 'exit' to leave chroot and return to LiveUSB             ║
║      Then unmount partitions and restart installation              ║
╚════════════════════════════════════════════════════════════════════╝
"
        bash
    fi
    exit 1
}

trap handle_error ERR INT TERM

###############################################################################
# First Stage: Outside chroot – Partitioning disk and extracting Void rootfs
###############################################################################

if [ -z "$VOID_INSTALL_STAGE_2" ]; then
    [[ $(id -u) == 0 ]] || error "This script must be run as root"
    command -v parted >/dev/null 2>&1 || error "parted not found. Install it"
    command -v xz >/dev/null 2>&1 || error "xz not found. Install it"
    command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || error "Neither curl nor wget is available. Install something"
    [ -n "$1" ] || error "Usage: $0 /dev/sdX (or /dev/nvme0n1, etc)"
    TARGET_DISK="$1"
    [ -b "$TARGET_DISK" ] || error "Target disk $TARGET_DISK does not exist or is not a block device."

    # Check if the target disk has any existing partitions.
    # English comment: List partitions on TARGET_DISK, excluding the disk itself.
    existing_partitions=$(lsblk -n -o NAME "$TARGET_DISK" | tail -n +2)
    if [ -n "$existing_partitions" ]; then
        error "Existing partitions detected on $TARGET_DISK. Remove all partitions before proceeding:
        ${BLUE}parted $TARGET_DISK mklabel gpt${NC}"
    fi

    export SCRIPT_STARTED=true
    echo "
          _______ _________ ______  
|\     /|(  ___  )\__   __/(  __  \ 
| )   ( || (   ) |   ) (   | (  \  )
| |   | || |   | |   | |   | |   ) |
( (   ) )| |   | |   | |   | |   | |
 \ \_/ / | |   | |   | |   | |   ) |
  \   /  | (___) |___) (___| (__/  )
   \_/   (_______)\_______/(______/ 
"

    # Determine partition naming scheme.
    # If disk name contains "nvme", partitions use 'p' separator (e.g. /dev/nvme0n1p1)
    if [[ "$TARGET_DISK" =~ nvme ]]; then
        PART_PREFIX="${TARGET_DISK}p"
    else
        PART_PREFIX="$TARGET_DISK"
    fi

    log "Partitioning disk $TARGET_DISK..."
    try parted -s "$TARGET_DISK" mklabel gpt
    try parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 513MiB
    try parted -s "$TARGET_DISK" set 1 esp on

    if [ "$SWAP_GB" -gt 0 ]; then
        SWAP_SIZE_MB=$(( SWAP_GB * 1024 ))
        SWAP_END=$(( 513 + SWAP_SIZE_MB ))
        try parted -s "$TARGET_DISK" mkpart primary linux-swap 513MiB "${SWAP_END}MiB"
        try parted -s "$TARGET_DISK" mkpart primary ext4 "${SWAP_END}MiB" 100%
    else
        try parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 100%
    fi

    log "Formatting EFI partition (${PART_PREFIX}1)..."
    try mkfs.fat -F32 "${PART_PREFIX}1"

    if [ "$SWAP_GB" -gt 0 ]; then
        log "Formatting swap partition (${PART_PREFIX}2)..."
        try mkswap "${PART_PREFIX}2"
        try swapon "${PART_PREFIX}2"
        ROOT_PARTITION="${PART_PREFIX}3"
    else
        ROOT_PARTITION="${PART_PREFIX}2"
    fi

    log "Formatting root partition (${ROOT_PARTITION})..."
    try mkfs.ext4 "${ROOT_PARTITION}"

    log "Mounting partitions..."
    try mount "${ROOT_PARTITION}" /mnt
    try mkdir -p /mnt/boot/efi
    try mount "${PART_PREFIX}1" /mnt/boot/efi

    log "Downloading Void Linux rootfs..."
    if command -v curl >/dev/null 2>&1; then
        try curl -fL "$VOID_LINK" -o "/mnt/rootfs.tar.xz"
    elif command -v wget >/dev/null 2>&1; then
        try wget -O "/mnt/rootfs.tar.xz" "$VOID_LINK"
    else
        error "Neither curl nor wget is available."
    fi

    log "Verifying SHA256 checksum of rootfs..."
    CALCULATED_HASH=$(sha256sum "/mnt/rootfs.tar.xz" | awk '{print $1}')
    if [ "$CALCULATED_HASH" != "$VOID_HASH" ]; then
        error "SHA256 checksum verification failed!"
    fi

    log "Extracting rootfs to /mnt..."
    try tar xf "/mnt/rootfs.tar.xz" -C /mnt
    try rm "/mnt/rootfs.tar.xz"

    log "Configuring fstab..."
    {
      echo "${ROOT_PARTITION} / ext4 defaults,noatime,discard 0 1"
      echo "${PART_PREFIX}1 /boot/efi vfat defaults,umask=0077 0 1"
      if [ "$SWAP_GB" -gt 0 ]; then
          SWAP_UUID=$(blkid -s UUID -o value "${PART_PREFIX}2" 2>/dev/null || true)
          if [ -n "$SWAP_UUID" ]; then
              echo "UUID=${SWAP_UUID} none swap sw 0 0"
          else
              echo "${PART_PREFIX}2 none swap sw 0 0"
          fi
      fi
    } >> /mnt/etc/fstab

    log "Setting hostname..."
    echo "$SET_HOSTNAME" > /mnt/etc/hostname
    try cp /etc/resolv.conf /mnt/etc/resolv.conf # For working dns in stage 2

    # Copy this installer script into new system for second stage.
    SCRIPT_PATH=$(readlink -f "$0")
    try cp "$SCRIPT_PATH" /mnt/void-install.sh

    log "Mounting necessary filesystems for chroot..."
    try mount --bind /dev /mnt/dev
    try mount --bind /proc /mnt/proc
    try mount --bind /sys /mnt/sys
    try mount --bind /run /mnt/run

    log "Entering chroot for second stage installation..."
    env VOID_INSTALL_STAGE_2=y chroot /mnt /void-install.sh

    exit 0
fi

###############################################################################
# Second Stage: Inside chroot – System configuration, package installation, GRUB
###############################################################################

log "Updating xbps..."
try xbps-install -Syu xbps

log "Updating packages..."
try xbps-install -Syu

log "Installing base system..."
try xbps-install -y base-system

log "Installing necessary packages..."
try xbps-install -y bind-utils inotify-tools psmisc parallel less jq unzip bc git
try xbps-install -y grub wget curl openssh bash-completion

log "Installing additional useful packages..."
try xbps-install -y $ADD_PKG

# Network setup based on WIFI option
if [ "$WIFI" = true ]; then
    log "Installing WiFi network manager (NetworkManager)..."
    try xbps-install -y NetworkManager
    ln -sf /etc/sv/dbus /etc/runit/runsvdir/default/
    ln -sf /etc/sv/NetworkManager /etc/runit/runsvdir/default/
else
    log "Installing DHCP client (dhcpcd)..."
    try xbps-install -y dhcpcd
    ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
fi

log "Installing simple cron (scron)..."
try xbps-install -y scron
ln -sf /etc/sv/crond /etc/runit/runsvdir/default/
cat > /etc/crontab <<EOF
# ┌───────────── minute (0 - 59)
# │ ┌───────────── hour (0 - 23)
# │ │ ┌───────────── day of month (1 - 31)
# │ │ │ ┌───────────── month (1 - 12)
# │ │ │ │ ┌───────────── day of week (0 - 6)
# │ │ │ │ │
0 4 * * * run-parts /etc/cron.daily &>> /var/log/cron.daily.log
EOF

log "Installing ufw (firewall)..."
try xbps-install -y ufw
ln -sf /etc/sv/ufw /etc/runit/runsvdir/default/
sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
#
echo "ufw allow ssh #VOID-INFECT-STAGE-3" >> /etc/rc.local 
echo "sed -i '/#VOID-INFECT-STAGE-3/d' /etc/rc.local " >> /etc/rc.local 

log "Setting up bash configuration..."
try wget https://raw.githubusercontent.com/Jipok/Cute-bash/master/.bashrc -O "/etc/bash/bashrc.d/cute-bash.sh"
try wget "https://raw.githubusercontent.com/trapd00r/LS_COLORS/master/LS_COLORS" -O "/etc/bash/ls_colors"
try wget "https://raw.githubusercontent.com/cykerway/complete-alias/master/complete_alias" -O "/etc/bash/complete_alias"
rm -f "/etc/skel/.bashrc" 2>/dev/null || true
usermod -s /bin/bash root || error "Failed to set bash as default shell"

if [[ -n "$ADD_LOCALE" ]]; then
    log "Setting locales..."
    sed -i "s/^# *$ADD_LOCALE/$ADD_LOCALE/" /etc/default/libc-locales
    try xbps-reconfigure -f glibc-locales
fi

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
# Set key
try mkdir -p /root/.ssh
echo "${SSH_KEY:-}" > /root/.ssh/authorized_keys

log "Installing bootloader..."
if [ -d "/sys/firmware/efi" ]; then
    try xbps-install -y grub-x86_64-efi efibootmgr
    try grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
else
    error "No EFI support detected. BIOS installation not implemented in this script."
fi
# Use traditional Linux naming scheme for interfaces and enable IPv6 support if needed
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0 /' /etc/default/grub
try update-grub

log "Installation complete"
log "Changing root password..."
passwd
read -p "Press enter to reboot..."
/sbin/reboot -f
