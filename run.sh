#!/bin/bash

set -Eeuo pipefail

# ============================================================
# Configuration
# ============================================================

CRYPT_NAME="crypt0"
CRYPT_DEV="/dev/sda2"
BOOT_DEV="/dev/sda1"

WG_INTERFACE="wg0"
WG_CONFIG="/mnt/etc/wireguard/${WG_INTERFACE}.conf"
LIVE_WG_CONFIG="/etc/wireguard/${WG_INTERFACE}.conf"

SSH_CONFIG="/etc/ssh/sshd_config.d/sshd.conf"

SSH_ADDRESS="10.8.0.8"
SSH_PORT="22022"

# ============================================================
# Error handling
# ============================================================

trap 'echo "ERROR: line $LINENO: $BASH_COMMAND" >&2' ERR

# ============================================================
# Cleanup
# ============================================================

cleanup()
{
    echo
    echo "========================================"
    echo "Cleaning up recovery environment"
    echo "========================================"

    echo "Unmounting /mnt/boot..."
    umount /mnt/boot 2>/dev/null || true

    echo "Unmounting /mnt recursively..."
    umount -l -n -R /mnt 2>/dev/null || true

    echo "Closing encrypted volume..."
    if [[ -e "/dev/mapper/${CRYPT_NAME}" ]]; then
        cryptsetup close "$CRYPT_NAME" 2>/dev/null || true
    fi

    echo
    echo "Cleanup complete."
}

quit_recovery()
{
    echo
    echo "Recovery aborted."
    cleanup
    exit 1
}

# ============================================================
# Retry handling
# ============================================================

retry_function()
{
    local function_name="$1"
    local description="$2"

    while true; do
        echo
        echo "========================================"
        echo "FAILED: $description"
        echo "========================================"
        echo

        read -rp "Retry this step? [r]etry / [q]uit: " choice

        case "$choice" in
            r|R)
                echo
                echo "Retrying: $description"
                echo

                if "$function_name"; then
                    echo
                    echo "SUCCESS: $description"
                    return 0
                fi
                ;;

            q|Q)
                quit_recovery
                ;;

            *)
                echo "Invalid choice."
                echo "Enter 'r' to retry or 'q' to quit."
                ;;
        esac
    done
}

run_step()
{
    local function_name="$1"
    local description="$2"

    echo
    echo "========================================"
    echo "$description"
    echo "========================================"

    if "$function_name"; then
        echo "SUCCESS: $description"
        return 0
    fi

    retry_function "$function_name" "$description"
}

# ============================================================
# Initial checks
# ============================================================

check_root()
{
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root."
        return 1
    fi

    return 0
}

check_base_commands()
{
    local commands=(
        iwctl
        reflector
        pacman
        cryptsetup
        mount
        umount
        systemctl
        ip
        ss
        passwd
        ssh-keygen
    )

    local command

    for command in "${commands[@]}"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "Missing required command: $command"
            return 1
        fi
    done

    return 0
}

# ============================================================
# Network
# ============================================================

connect_wifi()
{
    echo "Connecting to Wi-Fi..."

    if ! iwctl station wlan0 connect "Home sweet home"; then
        echo "Failed to connect to Wi-Fi."
        return 1
    fi

    sleep 3

    echo "Checking network connectivity..."

    if ! reflector \
        --verbose \
        --protocol https \
        --sort rate \
        --latest 5 \
        --country Japan \
        --save /etc/pacman.d/mirrorlist
    then
        echo "Network connectivity / reflector test failed."
        return 1
    fi

    return 0
}

# ============================================================
# Install required packages
# ============================================================

install_packages()
{
    echo "Refreshing package databases..."

    if ! pacman -Syy --noconfirm; then
        echo "Failed to refresh package databases."
        return 1
    fi

    echo "Installing WireGuard and OpenSSH..."

    if ! pacman -S --noconfirm \
        wireguard-tools \
        openssh
    then
        echo "Failed to install required packages."
        return 1
    fi

    if ! command -v wg >/dev/null 2>&1; then
        echo "wg command is missing after installation."
        return 1
    fi

    if ! command -v wg-quick >/dev/null 2>&1; then
        echo "wg-quick command is missing after installation."
        return 1
    fi

    if ! command -v sshd >/dev/null 2>&1; then
        echo "sshd command is missing after installation."
        return 1
    fi

    return 0
}

# ============================================================
# Open encrypted filesystem
# ============================================================

open_crypt()
{
    if [[ -e "/dev/mapper/${CRYPT_NAME}" ]]; then
        echo "${CRYPT_NAME} is already open."
        return 0
    fi

    if [[ ! -b "$CRYPT_DEV" ]]; then
        echo "Encrypted device does not exist: $CRYPT_DEV"
        return 1
    fi

    echo "Opening $CRYPT_DEV as $CRYPT_NAME..."

    if ! cryptsetup open "$CRYPT_DEV" "$CRYPT_NAME"; then
        echo "Failed to open encrypted filesystem."
        return 1
    fi

    sleep 2

    if [[ ! -e "/dev/mapper/${CRYPT_NAME}" ]]; then
        echo "/dev/mapper/${CRYPT_NAME} was not created."
        return 1
    fi

    return 0
}

# ============================================================
# Mount helper
# ============================================================

mount_subvol()
{
    local subvol="$1"
    local target="$2"

    mkdir -p "$target"

    if mountpoint -q "$target"; then
        echo "$target is already mounted."
        return 0
    fi

    echo "Mounting $subvol -> $target"

    if ! mount \
        -o "subvol=${subvol}" \
        "/dev/mapper/${CRYPT_NAME}" \
        "$target"
    then
        echo "Failed to mount $subvol at $target."
        return 1
    fi

    return 0
}

# ============================================================
# Mount installed system
# ============================================================

mount_root()
{
    mount_subvol "@" "/mnt"
}

mount_root_subvol()
{
    mount_subvol "@root" "/mnt/root"
}

mount_home()
{
    mount_subvol "@home" "/mnt/home"
}

mount_srv()
{
    mount_subvol "@srv" "/mnt/srv"
}

mount_cache()
{
    mount_subvol "@cache" "/mnt/var/cache"
}

mount_tmp()
{
    mount_subvol "@tmp" "/mnt/var/tmp"
}

mount_log()
{
    mount_subvol "@log" "/mnt/var/log"
}

mount_boot()
{
    mkdir -p /mnt/boot

    if mountpoint -q /mnt/boot; then
        echo "/mnt/boot is already mounted."
        return 0
    fi

    if [[ ! -b "$BOOT_DEV" ]]; then
        echo "Boot device does not exist: $BOOT_DEV"
        return 1
    fi

    echo "Mounting $BOOT_DEV -> /mnt/boot"

    if ! mount "$BOOT_DEV" /mnt/boot; then
        echo "Failed to mount $BOOT_DEV."
        return 1
    fi

    return 0
}

# ============================================================
# WireGuard configuration
# ============================================================

copy_wireguard_config()
{
    if [[ ! -f "$WG_CONFIG" ]]; then
        echo "Installed WireGuard configuration not found:"
        echo "$WG_CONFIG"
        return 1
    fi

    mkdir -p /etc/wireguard

    echo "Copying WireGuard configuration..."

    if ! cp "$WG_CONFIG" "$LIVE_WG_CONFIG"; then
        echo "Failed to copy WireGuard configuration."
        return 1
    fi

    chmod 600 "$LIVE_WG_CONFIG"

    if [[ ! -s "$LIVE_WG_CONFIG" ]]; then
        echo "Copied WireGuard configuration is empty."
        return 1
    fi

    return 0
}

# ============================================================
# SSH configuration
# ============================================================

configure_ssh()
{
    mkdir -p /etc/ssh/sshd_config.d

    echo "Generating SSH host keys..."

    if ! ssh-keygen -A; then
        echo "Failed to generate SSH host keys."
        return 1
    fi

    echo "Writing SSH configuration..."

    cat > "$SSH_CONFIG" <<'EOF'
ListenAddress 10.8.0.8
Port 22022
PermitRootLogin yes
PubkeyAuthentication no
PasswordAuthentication yes
EOF

    chmod 600 "$SSH_CONFIG"

    echo "Testing SSH configuration..."

    if ! sshd -t; then
        echo "sshd configuration test failed."
        return 1
    fi

    return 0
}

# ============================================================
# Root password
# ============================================================

set_root_password()
{
    echo
    echo "Set the root password for the ArchISO recovery environment."
    echo

    if ! passwd root; then
        echo "Failed to set root password."
        return 1
    fi

    return 0
}

# ============================================================
# WireGuard
# ============================================================

start_wireguard()
{
    echo "Starting ${WG_INTERFACE}..."

    if ! systemctl enable --now "wg-quick@${WG_INTERFACE}"; then
        echo "Failed to start ${WG_INTERFACE}."
        return 1
    fi

    sleep 3

    if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        echo "${WG_INTERFACE} interface does not exist."
        return 1
    fi

    echo
    wg show "$WG_INTERFACE"

    return 0
}

# ============================================================
# SSH
# ============================================================

start_ssh()
{
    echo "Starting sshd..."

    if ! systemctl restart sshd; then
        echo "Failed to start/restart sshd."
        return 1
    fi

    sleep 2

    if ! systemctl is-active --quiet sshd; then
        echo "sshd is not active."
        return 1
    fi

    echo "Checking SSH listener..."

    if ! ss -lnt | grep -q "${SSH_ADDRESS}:${SSH_PORT}"; then
        echo "sshd is not listening on ${SSH_ADDRESS}:${SSH_PORT}."
        echo
        ss -lnt
        return 1
    fi

    return 0
}

# ============================================================
# Final verification
# ============================================================

verify_recovery()
{
    echo
    echo "========================================"
    echo "Final verification"
    echo "========================================"

    echo
    echo "--- Filesystems ---"

    if ! findmnt /mnt >/dev/null 2>&1; then
        echo "/mnt is not mounted."
        return 1
    fi

    findmnt /mnt

    echo
    echo "--- WireGuard ---"

    if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        echo "${WG_INTERFACE} is not present."
        return 1
    fi

    wg show "$WG_INTERFACE"

    echo
    echo "--- SSH service ---"

    if ! systemctl is-active --quiet sshd; then
        echo "sshd is not active."
        return 1
    fi

    echo
    echo "--- SSH listener ---"

    if ! ss -lnt | grep -q "${SSH_ADDRESS}:${SSH_PORT}"; then
        echo "SSH is not listening on ${SSH_ADDRESS}:${SSH_PORT}."
        return 1
    fi

    ss -lnt | grep "$SSH_PORT"

    echo
    echo "All recovery checks passed."

    return 0
}

# ============================================================
# Main
# ============================================================

main()
{
    echo
    echo "========================================"
    echo "ArchISO Recovery Environment"
    echo "========================================"
    echo

    run_step check_root \
        "Checking root privileges"

    run_step check_base_commands \
        "Checking base ArchISO commands"

    run_step connect_wifi \
        "Connecting to Wi-Fi and configuring mirrors"

    run_step install_packages \
        "Installing WireGuard and OpenSSH"

    run_step open_crypt \
        "Opening encrypted filesystem"

    run_step mount_root \
        "Mounting @"

    run_step mount_root_subvol \
        "Mounting @root"

    run_step mount_home \
        "Mounting @home"

    run_step mount_srv \
        "Mounting @srv"

    run_step mount_cache \
        "Mounting @cache"

    run_step mount_tmp \
        "Mounting @tmp"

    run_step mount_log \
        "Mounting @log"

    run_step mount_boot \
        "Mounting boot partition"

    run_step copy_wireguard_config \
        "Copying WireGuard configuration"

    run_step configure_ssh \
        "Configuring SSH"

    # The password must exist before SSH is started.
    run_step set_root_password \
        "Setting root password"

    # wg0 must exist before sshd tries to bind to 10.8.0.8.
    run_step start_wireguard \
        "Starting WireGuard"

    run_step start_ssh \
        "Starting SSH"

    run_step verify_recovery \
        "Verifying recovery environment"

    echo
    echo "========================================"
    echo "Recovery environment ready."
    echo "========================================"
    echo
    echo "WireGuard: ${SSH_ADDRESS}"
    echo "SSH:       ${SSH_ADDRESS}:${SSH_PORT}"
    echo
}

main "$@"
