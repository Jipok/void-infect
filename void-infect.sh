#!//usr/bin/env bash
set -e  # Exit on any error

VOID_VERSION="void-x86_64-ROOTFS-20240314.tar.xz"
ADD_LOCALE="ru_RU.UTF-8" # Optional
ADD_PKG="fuzzypkg vsv fzf tmux dte gotop"
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

run_cmd() {
    local cmd="$1"
    local log_file=$(mktemp)
    
    if ! eval "$cmd" &> "$log_file"; then
        cat "$log_file"
        error "Failed: $cmd"
    fi
    rm -f "$log_file"
}

setup_void() {
    log "Updating xbps..."
    run_cmd "xbps-install -Syu xbps"
    log "Updating system..."
    run_cmd "xbps-install -Syu"
    log "Installing base system..."
    run_cmd "xbps-install -y base-system"

    log "Installing necessary packages..."
    run_cmd "xbps-install -y grub dhcpcd rsync wget curl vim nano git openssh"
    
    log "Installing useful packages [$ADD_PKG]..."
    run_cmd "xbps-install -y $ADD_PKG"
    
    log "Installing simple cron..."
    run_cmd "xbps-install -y scron"
    ln -sf /etc/sv/crond /etc/runit/runsvdir/default/

    log "Setting hostname..."
    echo "$SET_HOSTNAME" > /etc/hostname

    if [[ ! -z "$ADD_LOCALE" ]]; then
        log "Setting locales..."
        sed -i "s/^# *$ADD_LOCALE/$ADD_LOCALE/" /etc/default/libc-locales
        run_cmd "xbps-reconfigure -f glibc-locales"
    fi

    log "Configuring network..."
    interface=$(ip route show default | head -n1 | awk '{print $5}')
    ip_addr=$(ip addr show dev "$interface" | grep 'inet ' | awk '{print $2}')
    gateway=$(ip route show default | head -n1 | awk '{print $3}')
    ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
    cat > /etc/dhcpcd.conf << EOL
interface eth0
static ip_address=${ip_addr}
static routers=${gateway}
static domain_name_servers=1.1.1.1 8.8.8.8
EOL

    log "Configuring SSH..."
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    ln -sf /etc/sv/sshd /etc/runit/runsvdir/default/

    # log "Setting root password..."
    # echo "root:voidlinux" | chpasswd
    
    log "Disabling root password login..."
    passwd -l root || error "Failed to disable password"

    log "Removing sudo..."
    echo "ignorepkg=sudo" > /etc/xbps.d/no-sudo.conf
    run_cmd "xbps-install -y opendoas"
    run_cmd "xbps-remove -y sudo"
    log "Setting bash as default shell..."
    usermod -s /bin/bash root || error "Failed to set bash as default shell"

    log "Installing bootloader..."
    if [[ ! -e /dev/vda ]]; then
        error "Disk /dev/vda not found"
    fi
    run_cmd "grub-install /dev/vda"
    # Use traditional Linux naming scheme for interfaces
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0 /' /etc/default/grub
    run_cmd "update-grub"

    log "Configuring fstab..."
    echo "/dev/vda1 / ext4 defaults 0 1" > /etc/fstab
}

replace_system() {
    if ! mount /dev/vda1 /mnt; then
        error "Failed to mount root partition"
    fi

    cd /mnt || error "Failed to change directory to /mnt"
    find . -mindepth 1 -not \( -path './dev*' -o -path './proc*' -o -path './sys*' -o -path './mnt*' -o -path './run*' -o -path './tmp*' \) -delete

    rsync -aAX --delete \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
        / /mnt/

    sync
    cd /
    umount /mnt || error "Failed to unmount /mnt"
}

main() {
    [[ $(id -u) == 0 ]] || error "This script must be run as root"

    log "Creating temporary directories..."
    TEMP_DIR=$(mktemp -d)
    VOID_MOUNT="$TEMP_DIR/void"
    OLD_ROOT="$TEMP_DIR/oldroot"
    mkdir -p "$VOID_MOUNT" "$OLD_ROOT"
    cd "$TEMP_DIR" || error "Failed to change directory"

    log "Downloading Void Linux rootfs..."
    wget -q "https://repo-default.voidlinux.org/live/current/$VOID_VERSION" || error "Failed to download rootfs"

    log "Extracting rootfs..."
    tar xf "$VOID_VERSION" -C "$VOID_MOUNT" || error "Failed to extract rootfs"

    log "Mounting necessary filesystems..."
    mount --bind / "$OLD_ROOT" || error "Failed to mount old root"
    mount --bind /dev "$VOID_MOUNT/dev" || error "Failed to mount /dev"
    mount --bind /proc "$VOID_MOUNT/proc" || error "Failed to mount /proc"
    mount --bind /sys "$VOID_MOUNT/sys" || error "Failed to mount /sys"

    log "Copying essential files..."
    cp "$SCRIPT_PATH" "$VOID_MOUNT/root/install.sh" || error "Failed to copy install script"
    chmod +x "$VOID_MOUNT/root/install.sh"
    cp /etc/resolv.conf "$VOID_MOUNT/etc/" || error "Failed to copy resolv.conf"
    mkdir -p "$VOID_MOUNT/root/.ssh"
    cp -r /root/.ssh/authorized_keys "$VOID_MOUNT/root/.ssh/" || error "Failed to copy SSH keys"
    chmod 700 "$VOID_MOUNT/root/.ssh"
    chmod 600 "$VOID_MOUNT/root/.ssh/authorized_keys"

    log "Setting up bash configuration..."
    wget -q https://raw.githubusercontent.com/Jipok/Cute-bash/master/.bashrc -O "$VOID_MOUNT/etc/bash/bashrc.d/cute-bash.sh" || error "Failed to download cute-bash"
    wget -q "https://raw.githubusercontent.com/trapd00r/LS_COLORS/master/LS_COLORS" -O "$VOID_MOUNT/etc/bash/ls_colors" || error "Failed to download LS_COLORS"
    wget -q "https://raw.githubusercontent.com/cykerway/complete-alias/master/complete_alias" -O "$VOID_MOUNT/etc/bash/complete_alias" || error "Failed to download complete-alias"
    wget -q "https://raw.githubusercontent.com/scop/bash-completion/2.11/bash_completion" -O "$VOID_MOUNT/etc/bash/bash-completion-2.11" || error "Failed to download bash-completion"
    rm "$VOID_MOUNT/etc/skel/.bashrc" 2>/dev/null || true

    log "Entering chroot and performing setup..."
    chroot "$VOID_MOUNT" /root/install.sh --setup || error "Setup failed"

    log "Replacing system..."
    chroot "$VOID_MOUNT" /root/install.sh --replace || error "System replacement failed"

    log "Cleaning up..."
    for mount in "$VOID_MOUNT/dev" "$VOID_MOUNT/proc" "$VOID_MOUNT/sys" "$VOID_MOUNT" "$OLD_ROOT"; do
        umount "$mount" 2>/dev/null || true
    done

    log "System replacement complete. Rebooting in 5 seconds..."
    sync
    sleep 1

    IP_ADDRESS=$(ip route get 1 2>/dev/null | awk '{print $7}' | head -1)
    FORMATTED_IP=$(printf "%-15s" "${IP_ADDRESS}")
    cat << EOF

╔════════════════════════════════════════════════════════════════════╗
║                     IMPORTANT INFORMATION                          ║
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
║   ssh-keygen -R ${FORMATTED_IP}                                    ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
EOF

    sleep 4

    /sbin/reboot -f
}

case "${1:-}" in
    --setup)
        setup_void
        ;;
    --replace)
        replace_system
        ;;
    *)
        SCRIPT_PATH=$(readlink -f "$0")
        main
        ;;
esac
