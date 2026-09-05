#!/bin/bash
# =====================================================================
# Pomera DM250 Backup & Restore Tool - Shared Utility Library
# Contains common constants, partition geometry, device helpers,
# checksum utilities, and unmount handlers across Linux & macOS.
# =====================================================================

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

# ---------------------------------------------------------------------
# Device Node & Unmount Helpers
# ---------------------------------------------------------------------

# Resolve disk node on macOS (/dev/rdiskN <-> /dev/diskN)
resolve_disk_node() {
    local dev="$1"
    if [ "$OS_NAME" = "Darwin" ]; then
        if [[ "$dev" =~ ^/dev/rdisk([0-9]+.*)$ ]]; then
            echo "/dev/disk${BASH_REMATCH[1]}"
        elif [[ "$dev" =~ ^/dev/disk([0-9]+.*)$ ]]; then
            echo "/dev/disk${BASH_REMATCH[1]}"
        elif [[ "$dev" =~ ^rdisk([0-9]+.*)$ ]]; then
            echo "/dev/disk${BASH_REMATCH[1]}"
        elif [[ "$dev" =~ ^disk([0-9]+.*)$ ]]; then
            echo "/dev/disk${BASH_REMATCH[1]}"
        else
            echo "$dev"
        fi
    else
        echo "$dev"
    fi
}

resolve_raw_disk_node() {
    local dev="$1"
    if [ "$OS_NAME" = "Darwin" ]; then
        if [[ "$dev" =~ ^/dev/disk([0-9]+.*)$ ]]; then
            echo "/dev/rdisk${BASH_REMATCH[1]}"
        elif [[ "$dev" =~ ^/dev/rdisk([0-9]+.*)$ ]]; then
            echo "/dev/rdisk${BASH_REMATCH[1]}"
        elif [[ "$dev" =~ ^disk([0-9]+.*)$ ]]; then
            echo "/dev/rdisk${BASH_REMATCH[1]}"
        elif [[ "$dev" =~ ^rdisk([0-9]+.*)$ ]]; then
            echo "/dev/rdisk${BASH_REMATCH[1]}"
        else
            echo "$dev"
        fi
    else
        echo "$dev"
    fi
}

# Automatically unmount target device volumes (macOS & Linux)
unmount_target_device() {
    local dev="$1"
    if [ "$OS_NAME" = "Darwin" ]; then
        local disk_node
        disk_node="$(resolve_disk_node "$dev")"
        if diskutil info "$disk_node" 2>/dev/null | grep -qi "Mounted: *Yes" || mount | grep -q "^$disk_node"; then
            echo "🔄 Unmounting auto-mounted volumes on $disk_node..."
            diskutil unmountDisk "$disk_node" 2>/dev/null || true
        else
            diskutil unmountDisk "$disk_node" >/dev/null 2>&1 || true
        fi
    else
        local mounts
        mounts=$(lsblk -ln -o MOUNTPOINTS "$dev" 2>/dev/null | grep -v '^$' || true)
        if [ -n "$mounts" ]; then
            echo "🔄 Unmounting auto-mounted volumes on $dev..."
            echo "$mounts" | while read -r mp; do
                [ -n "$mp" ] && umount "$mp" 2>/dev/null || true
            done
        fi
    fi
}

# ---------------------------------------------------------------------
# External Block Devices Detection
# ---------------------------------------------------------------------
show_block_devices() {
    echo "Current external block devices detected on system:"
    if [ "$OS_NAME" = "Darwin" ]; then
        local ext_disks
        ext_disks=$(diskutil list external 2>/dev/null || true)
        if [ -n "$ext_disks" ]; then
            echo "$ext_disks"
        else
            echo "   (No external disks detected. Make sure Pomera is in UMS mode and connected via USB.)"
        fi
    else
        local ext_disks
        ext_disks=$(lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -E "usb|mmc" || true)
        if [ -n "$ext_disks" ]; then
            echo "$ext_disks"
        else
            lsblk -e 7 -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINTS 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------
# Device Size and Formatting Helpers
# ---------------------------------------------------------------------
get_device_size_bytes() {
    local dev="$1"
    local dev_bytes=""
    if [ "$OS_NAME" = "Darwin" ]; then
        dev_bytes=$(diskutil info "$dev" 2>/dev/null | awk '/Disk Size:/ {print $5}' | tr -d '()' || true)
    else
        dev_bytes=$( (blockdev --getsize64 "$dev" 2>/dev/null || lsblk -b -n -o SIZE "$dev" 2>/dev/null | head -n1) || true )
    fi
    echo "$dev_bytes"
}

format_bytes_to_gb() {
    local bytes="$1"
    if [ -n "$bytes" ] && [[ "$bytes" =~ ^[0-9]+$ ]]; then
        awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }' 2>/dev/null || echo "Unknown"
    else
        echo "Unknown"
    fi
}

# ---------------------------------------------------------------------
# Checksum Calculation Helpers
# ---------------------------------------------------------------------
calc_file_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

calc_stream_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------
# File Ownership Helper
# ---------------------------------------------------------------------
fix_file_ownership() {
    local target_path="$1"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -e "$target_path" ]; then
        chown -R "$SUDO_USER" "$target_path" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------
# Partition Geometry (in Megabytes, 1024*1024 bytes) - Bash 3.2 Compatible
# ---------------------------------------------------------------------
get_part_offset() {
    local name="$1"
    case "$name" in
        "dm250-idb.img") echo 0 ;;
        "mmcblk0p1.img") echo 8 ;;
        "mmcblk0p2.img") echo 16 ;;
        "mmcblk0p3.img") echo 28 ;;
        "mmcblk0p4.img") echo 34 ;;
        "mmcblk0p5.img") echo 98 ;;
        "mmcblk0p6.img") echo 610 ;;
        "mmcblk0p7.img") echo 866 ;;
        "mmcblk0p8.img") echo 2146 ;;
        "mmcblk0p9.img") echo 3170 ;;
        "mmcblk0p10.img") echo 3174 ;;
        "mmcblk0p11.img") echo 3176 ;;
        "mmcblk0p12.img") echo 3177 ;;
        "mmcblk0p13.img") echo 3433 ;;
        "mmcblk0p14.img") echo 3465 ;;
        "mmcblk0p15.img") echo 3477 ;;
        "mmcblk0p16.img") echo 3541 ;;
        "mmcblk0p17.img") echo 3553 ;;
        "mmcblk0p18.img") echo 3559 ;;
        "mmcblk0p19.img") echo 3623 ;;
        "mmcblk0p20.img") echo 4135 ;;
        "mmcblk0p21.img") echo 4391 ;;
        "mmcblk0p22.img") echo 4395 ;;
        "mmcblk0p23.img") echo 4651 ;;
        "mmcblk0p24.img") echo 4907 ;;
        "mmcblk0p25.img") echo 4909 ;;
        "mmcblk0p26.img") echo 6189 ;;
        "mmcblk0p27.img") echo 6829 ;;
        *) echo "" ;;
    esac
}

get_part_size() {
    local name="$1"
    case "$name" in
        "dm250-idb.img") echo 4 ;;
        "mmcblk0p1.img") echo 8 ;;
        "mmcblk0p2.img") echo 12 ;;
        "mmcblk0p3.img") echo 6 ;;
        "mmcblk0p4.img") echo 64 ;;
        "mmcblk0p5.img") echo 512 ;;
        "mmcblk0p6.img") echo 256 ;;
        "mmcblk0p7.img") echo 1280 ;;
        "mmcblk0p8.img") echo 1024 ;;
        "mmcblk0p9.img") echo 4 ;;
        "mmcblk0p10.img") echo 2 ;;
        "mmcblk0p11.img") echo 1 ;;
        "mmcblk0p12.img") echo 256 ;;
        "mmcblk0p13.img") echo 32 ;;
        "mmcblk0p14.img") echo 12 ;;
        "mmcblk0p15.img") echo 64 ;;
        "mmcblk0p16.img") echo 12 ;;
        "mmcblk0p17.img") echo 6 ;;
        "mmcblk0p18.img") echo 64 ;;
        "mmcblk0p19.img") echo 512 ;;
        "mmcblk0p20.img") echo 256 ;;
        "mmcblk0p21.img") echo 4 ;;
        "mmcblk0p22.img") echo 256 ;;
        "mmcblk0p23.img") echo 256 ;;
        "mmcblk0p24.img") echo 2 ;;
        "mmcblk0p25.img") echo 1280 ;;
        "mmcblk0p26.img") echo 640 ;;
        "mmcblk0p27.img") echo 0 ;; # 0 means until end of device
        *) echo "" ;;
    esac
}
