#!/usr/bin/env bash
# This is a script for installing Void on a home server
set -e  # Exit on any error

#=========================================================================
#                          CONFIGURATION
#=========================================================================

SET_HOSTNAME="void-server"
ADD_LOCALE="ru_RU.UTF-8"  # Optional locale
INSTALL_NTP=true

WIFI=true            # If true, install NetworkManager (for WiFi); if false, install dhcpcd (for wired)

SWAPFILE_GB=AUTO     # Swapfile size in GB or AUTO (based on RAM); 0 to disable
                     # NOTE: Using swapfile is preferred over swap partition (more flexible)
SWAP_GB=0            # Swap partition size in gigabytes; 0 for not creating partition

ADD_PKG="fuzzypkg vsv tmux dte nano gotop fd ncdu git tree fastfetch void-repo-nonfree"

USE_JIPOK_REPO=true
ADD_PKG2="cute-bash jsysctl"

#=========================================================================
#                       HELPER FUNCTIONS
#=========================================================================

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

SSH_KEY="${SSH_KEY:-}"

# Logging functions
log() {
    echo -e "${GREEN}[+]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[!]${NC} $1"
    handle_error
}

# Critical try: exits script on failure
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

# Soft try: warns on failure but continues execution
try_soft() {
    local log_file=$(mktemp)

    if ! eval "$@" &> "$log_file"; then
        echo -e "${YELLOW}[!] Optional step failed: $*${NC}"
        cat "$log_file"
        rm -f "$log_file"
        return 1
    fi
    rm -f "$log_file"
    return 0
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
    (command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1) || error "This script requires either curl or wget to download files."
    command -v parted >/dev/null 2>&1 || error "parted not found. Install it"
    command -v xz >/dev/null 2>&1 || error "xz not found. Install it"
    command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || error "Neither curl nor wget is available. Install something"
    [ -n "$1" ] || error "Usage: $0 /dev/sdX (or /dev/nvme0n1, etc)"
    TARGET_DISK="$1"
    [ -b "$TARGET_DISK" ] || error "Target disk $TARGET_DISK does not exist or is not a block device."

    # Check if the target disk has any existing partitions.
    existing_partitions=$(lsblk -n -o NAME "$TARGET_DISK" | tail -n +2)
    if [ -n "$existing_partitions" ]; then
        error "Existing partitions detected on $TARGET_DISK. Remove all partitions before proceeding:
        ${BLUE}parted $TARGET_DISK mklabel gpt${NC}"
    fi

    export SCRIPT_STARTED=true
    echo "
          _______ _________ ______
|\     /|(  ___  )\__   __/(  __  \\
| )   ( || (   ) |   ) (   | (  \  )
| |   | || |   | |   | |   | |   ) |
( (   ) )| |   | |   | |   | |   | |
 \ \_/ / | |   | |   | |   | |   ) |
  \   /  | (___) |___) (___| (__/  )
   \_/   (_______)\_______/(______/
"

    # Process SSH Key argument (Username or Raw Key)
    SSH_ARG="$2"
    if [ -n "$SSH_ARG" ]; then
        if [[ "$SSH_ARG" == ssh-* ]]; then
            log "Using provided raw SSH key."
            SSH_KEY="$SSH_ARG"
        else
            log "Fetching SSH keys from GitHub for user: $SSH_ARG"
            KEYS_URL="https://github.com/${SSH_ARG}.keys"
            TEMP_KEYS=$(mktemp)

            if command -v curl >/dev/null 2>&1; then
                curl -fsL "$KEYS_URL" -o "$TEMP_KEYS" || error "Failed to fetch keys for '$SSH_ARG'"
            else
                wget -qO "$TEMP_KEYS" "$KEYS_URL" || error "Failed to fetch keys for '$SSH_ARG'"
            fi

            if [ -s "$TEMP_KEYS" ]; then
                SSH_KEY=$(cat "$TEMP_KEYS")
                rm "$TEMP_KEYS"
            else
                rm "$TEMP_KEYS"
                error "No keys found for GitHub user '$SSH_ARG'"
            fi
        fi
    fi

    # Check if we have any key at all
    if [ -z "$SSH_KEY" ]; then
        echo -e "${RED}[WARNING]${NC} No SSH key provided (via config or argument). Login via SSH will be impossible."
        echo "Waiting 7 seconds..."
        sleep 7
    fi

    log "Fetching the latest image information..."
    if command -v curl >/dev/null 2>&1; then
        IMAGE_INFO=$(curl -s https://repo-default.voidlinux.org/live/current/sha256sum.txt | grep 'void-x86_64-ROOTFS-' | grep -v 'musl')
    elif command -v wget >/dev/null 2>&1; then
        IMAGE_INFO=$(wget -qO- https://repo-default.voidlinux.org/live/current/sha256sum.txt | grep 'void-x86_64-ROOTFS-' | grep -v 'musl')
    fi
    [ -n "$IMAGE_INFO" ] || error "Could not find image info in sha256sum.txt"

    # Parse filename, link and hash from the fetched info
    VOID_FILENAME=$(echo "$IMAGE_INFO" | sed -n 's/.*(\(.*\)).*/\1/p')
    [ -n "$VOID_FILENAME" ] || error "Could not parse filename from image info."
    VOID_LINK="https://repo-default.voidlinux.org/live/current/$VOID_FILENAME"
    VOID_HASH=$(echo "$IMAGE_INFO" | awk '{print $4}')
    [ -n "$VOID_HASH" ] || error "Could not parse hash from image info."

    # VOID_LINK="https://repo-default.voidlinux.org/live/current/void-x86_64-ROOTFS-20250202.tar.xz"
    # VOID_HASH="3f48e6673ac5907a897d913c97eb96edbfb230162731b4016562c51b3b8f1876"

    #-------------------------------------------------------------------------
    # Disk partitioning
    #-------------------------------------------------------------------------
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

    #-------------------------------------------------------------------------
    # Formatting partitions
    #-------------------------------------------------------------------------

    # Determine partition naming scheme.
    # If disk name contains "nvme", partitions use 'p' separator (e.g. /dev/nvme0n1p1)
    if [[ "$TARGET_DISK" =~ nvme ]]; then
        PART_PREFIX="${TARGET_DISK}p"
    else
        PART_PREFIX="$TARGET_DISK"
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

    #-------------------------------------------------------------------------
    # Mounting and setup
    #-------------------------------------------------------------------------
    log "Mounting partitions..."
    try mount "${ROOT_PARTITION}" /mnt
    try mkdir -p /mnt/boot/efi
    try mount "${PART_PREFIX}1" /mnt/boot/efi

    log "Downloading Void Linux rootfs..."
    if command -v curl >/dev/null 2>&1; then
        try curl -fL "$VOID_LINK" -o "/mnt/rootfs.tar.xz"
    elif command -v wget >/dev/null 2>&1; then
        try wget -O "/mnt/rootfs.tar.xz" "$VOID_LINK"
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

    # Copy this installer script into new system for second stage
    SCRIPT_PATH=$(readlink -f "$0")
    try cp "$SCRIPT_PATH" /mnt/void-install.sh

    log "Mounting necessary filesystems for chroot..."
    try mount --bind /dev /mnt/dev
    try mount --bind /proc /mnt/proc
    try mount --bind /sys /mnt/sys
    try mount --bind /run /mnt/run

    log "Entering chroot for second stage installation..."
    env VOID_INSTALL_STAGE_2=y SSH_KEY="$SSH_KEY" chroot /mnt /void-install.sh

    exit 0
fi

##################################################################################
# Second Stage: Inside chroot – System configuration, package installation, GRUB
##################################################################################

log "Updating xbps..."
try xbps-install -Syu xbps

log "Updating packages..."
try xbps-install -Syu

log "Installing base system..."
try xbps-install -y base-system

#-------------------------------------------------------------------------
# Package Installation
#-------------------------------------------------------------------------
log "Installing necessary packages..."
# Utils used by scripts
try xbps-install -y bind-utils inotify-tools psmisc parallel less jq unzip bc git net-tools
# We need it
try xbps-install -y grub wget curl openssh bash-completion

log "Installing additional useful packages..."
try xbps-install -y $ADD_PKG

if [ "$USE_JIPOK_REPO" = true ]; then
    log "Setting up custom repository..."

    if try_soft wget --content-disposition -P /var/db/xbps/keys/ https://void-repo.jipok.ru/key; then
        echo "repository=https://void-repo.jipok.ru" > /etc/xbps.d/10-vur-Jipok.conf

        # Update index to verify connection
        if try_soft xbps-install -S; then
            CUSTOM_REPO_READY=true
        else
            warn "Failed to sync custom repository. Removing config."
            rm -f /etc/xbps.d/10-vur-Jipok.conf
        fi
    else
        warn "Failed to download custom repository key. Skipping."
    fi
fi

if [ -n "$ADD_PKG2" ]; then
    if [ "$CUSTOM_REPO_READY" = true ]; then
        log "Installing packages from void-repo.jipok.ru..."
        try_soft xbps-install -y $ADD_PKG2
    else
        warn "Skipping installation: $ADD_PKG2"
    fi
fi

#-------------------------------------------------------------------------
# Network Configuration
#-------------------------------------------------------------------------
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

#-------------------------------------------------------------------------
# NTP (Time Sync) Setup
#-------------------------------------------------------------------------
if [ "$INSTALL_NTP" = true ]; then
    log "Installing NTP client (openntpd)..."
    try xbps-install -y openntpd
    ln -sf /etc/sv/openntpd /etc/runit/runsvdir/default/
fi

#-------------------------------------------------------------------------
# Cron Setup
#-------------------------------------------------------------------------
log "Installing simple cron (scron)..."
try xbps-install -y scron
ln -sf /etc/sv/crond /etc/runit/runsvdir/default/
cat > /etc/crontab <<EOF
#
# * (wildcard), 30 (number), */N (repeat), 1-5 (range), or 1,3,6 (list)
#
# ┌───────────── minute (0 - 59)
# │ ┌───────────── hour (0 - 23)
# │ │ ┌───────────── day of month (1 - 31)
# │ │ │ ┌───────────── month (1 - 12)
# │ │ │ │ ┌───────────── day of week (0 - 6)
# │ │ │ │ │
# m h dom mon dow   command

# Run hourly jobs at minute 01
1 * * * * run-parts /etc/cron.hourly >> /var/log/cron.hourly.log 2>&1

# Run daily jobs at 05:00
0 5 * * * run-parts /etc/cron.daily >> /var/log/cron.daily.log 2>&1

# Run weekly jobs at 04:00 on Sunday
0 4 * * 0 run-parts /etc/cron.weekly >> /var/log/cron.weekly.log 2>&1

# Run monthly jobs at 03:00 on the first day of the month
0 3 1 * * run-parts /etc/cron.monthly >> /var/log/cron.monthly.log 2>&1

###########################

EOF
try mkdir -p /etc/cron.hourly
try mkdir -p /etc/cron.daily
try mkdir -p /etc/cron.weekly
try mkdir -p /etc/cron.monthly

#-------------------------------------------------------------------------
# Firewall Setup
#-------------------------------------------------------------------------
log "Installing ufw (firewall)..."
try xbps-install -y ufw
ln -sf /etc/sv/ufw /etc/runit/runsvdir/default/
sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
#
echo "ufw allow ssh #VOID-INFECT-STAGE-3" >> /etc/rc.local
echo "sed -i '/#VOID-INFECT-STAGE-3/d' /etc/rc.local " >> /etc/rc.local

#-------------------------------------------------------------------------
# Locale Configuration
#-------------------------------------------------------------------------
if [[ -n "$ADD_LOCALE" ]]; then
    log "Setting locales..."
    sed -i "s/^# *$ADD_LOCALE/$ADD_LOCALE/" /etc/default/libc-locales
    try xbps-reconfigure -f glibc-locales
fi

#-------------------------------------------------------------------------
# SSH Configuration
#-------------------------------------------------------------------------
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
try chmod 700 /root/.ssh
echo "$SSH_KEY" > /root/.ssh/authorized_keys

#-------------------------------------------------------------------------
# SWAP Configuration
#-------------------------------------------------------------------------
# Calculate total memory (in MB)
mem_total_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
TOTAL_MEM=$((mem_total_kb / 1024))

# Auto-select swap size based on available RAM
if [ "$SWAPFILE_GB" = "AUTO" ]; then
    if [ "$TOTAL_MEM" -le 1500 ]; then       # ~ 1 GB
        SWAPFILE_GB=2     # 2x RAM
    elif [ "$TOTAL_MEM" -le 2500 ]; then     # ~ 2 GB
        SWAPFILE_GB=2     # 1x RAM
    elif [ "$TOTAL_MEM" -le 4500 ]; then     # 3-4 GB
        SWAPFILE_GB=4     # ~1x RAM
    elif [ "$TOTAL_MEM" -le 11000 ]; then    # 5-8 GB
        SWAPFILE_GB=4     # ~0.5-0.8x RAM
    else                                     # 16+ GB
        SWAPFILE_GB=8     # ~0.5x RAM
    fi
fi

# Create swapfile if needed
if [ "$SWAPFILE_GB" -gt 0 ]; then
    log "Creating ${SWAPFILE_GB}GB swapfile..."
    try fallocate -l ${SWAPFILE_GB}G /swapfile
    try chmod 600 /swapfile
    try mkswap /swapfile
    try swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

#-------------------------------------------------------------------------
# Bootloader Installation
#-------------------------------------------------------------------------
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

#-------------------------------------------------------------------------
# Installation Complete
#-------------------------------------------------------------------------
log "Installation complete"

log "Change root password:"
try usermod -s /bin/bash root
if ! passwd; then
    echo -e "${RED}[WARNING]${NC} Password change failed or was skipped."
    echo -e "The root password defaults to: ${BLUE}voidlinux${NC}"
fi

echo -e "
╔════════════════════════════════════════════════════════════════════╗
║                   INSTALLATION SUCCESSFUL                          ║
╠════════════════════════════════════════════════════════════════════╣
║ You are now inside a shell in your new system.                     ║
║                                                                    ║
║ 1. You can install extra packages (xbps-install ...)               ║
║ 2. Check configs in /etc/                                          ║
║ 3. Type 'exit' to leave chroot and return to the Live environment  ║
╚════════════════════════════════════════════════════════════════════╝
"

/bin/bash
