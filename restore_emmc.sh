#!/bin/bash
# =====================================================================
# Pomera DM250 Direct eMMC Restore Script (with Checksum Verification)
# Restores backup image files to the UMS-mounted eMMC disk
# Cross-Platform Support: Linux (x86_64, aarch64, armhf) & macOS (Apple Silicon / Intel)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

EMMC_DEV="${1:-}"
IMG_DIR_ARG="${2:-}"

OS_NAME="$(uname -s)"

echo "=========================================================="
echo "  Pomera DM250 eMMC Direct Restore Tool (with Verify)"
echo "  Host Platform: $OS_NAME ($(uname -m))"
echo "=========================================================="
echo "ℹ️  Expected Performance:"
echo "   - Write speed:  ~4.8 - 5.0 MB/s"
echo "   - Verify speed: ~15 - 25 MB/s"
echo "   - Estimated total time for 27 partitions (7.3GB): ~25 - 30 minutes"
echo "=========================================================="

show_block_devices() {
    echo "Current block devices detected on system:"
    if [ "$OS_NAME" = "Darwin" ]; then
        diskutil list
    else
        lsblk -e 7 -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINTS
    fi
}

if [ -z "$EMMC_DEV" ] || [ "$EMMC_DEV" = "-h" ] || [ "$EMMC_DEV" = "--help" ]; then
    echo "Usage: sudo ./restore_emmc.sh <target_device> [image_directory]"
    echo ""
    echo "Arguments:"
    echo "  target_device   : Pomera eMMC device in UMS mode (Linux: /dev/sdb, macOS: /dev/rdiskN)"
    echo "  image_directory : Directory containing backup images (default: ./restore_file or ./backup_file)"
    echo ""
    echo "Examples:"
    if [ "$OS_NAME" = "Darwin" ]; then
        echo "  sudo ./restore_emmc.sh /dev/rdisk2"
        echo "  sudo ./restore_emmc.sh /dev/rdisk2 ./backup_file"
    else
        echo "  sudo ./restore_emmc.sh /dev/sdb"
        echo "  sudo ./restore_emmc.sh /dev/sdb ./restore_file"
    fi
    echo ""
    show_block_devices
    exit 1
fi

if [ ! -b "$EMMC_DEV" ] && [ ! -c "$EMMC_DEV" ]; then
    echo "⚠️ Error: '$EMMC_DEV' is not a valid block or character device."
    exit 1
fi

# Detect Image Directory (restore_file / backup_file / current directory / user specified)
IMG_DIR="."
if [ -n "$IMG_DIR_ARG" ] && [ -d "$IMG_DIR_ARG" ]; then
    IMG_DIR="$IMG_DIR_ARG"
elif [ -d "restore_file" ]; then
    IMG_DIR="restore_file"
elif [ -d "backup_file" ]; then
    IMG_DIR="backup_file"
fi

echo "Source Image Directory: $IMG_DIR"

# Safety check: Block device size
DEV_BYTES=""
if [ "$OS_NAME" = "Darwin" ]; then
    DEV_BYTES=$(diskutil info "$EMMC_DEV" 2>/dev/null | awk '/Disk Size:/ {print $5}' | tr -d '()' || true)
else
    DEV_BYTES=$( (blockdev --getsize64 "$EMMC_DEV" 2>/dev/null || lsblk -b -n -o SIZE "$EMMC_DEV" 2>/dev/null | head -n1) || true )
fi
DEV_GB=$( ([ -n "$DEV_BYTES" ] && echo "scale=2; $DEV_BYTES / 1024 / 1024 / 1024" | bc 2>/dev/null) || echo "Unknown" )

echo "Target Device: $EMMC_DEV (Size: approx ${DEV_GB} GB / ${DEV_BYTES:-0} bytes)"

# Warn if target is not ~7.3GB - 8.0GB
if [ -n "$DEV_BYTES" ]; then
    if [ "$DEV_BYTES" -gt 10000000000 ] || [ "$DEV_BYTES" -lt 6000000000 ]; then
        echo ""
        echo "🚨 CRITICAL WARNING: Device size (${DEV_GB} GB) does not match expected Pomera eMMC size (~7.3GB / 8GB)!"
        echo "Please double check if '$EMMC_DEV' is REALLY the Pomera DM250."
        echo ""
    fi
fi

echo "=========================================================="
echo "⚠️  WARNING: You are about to OVERWRITE all data on $EMMC_DEV"
echo "Make sure this is the Pomera DM250 eMMC disk!"
echo "=========================================================="
read -p "Are you absolutely sure you want to proceed? (yes/N): " CONFIRM
if [ "${CONFIRM:-}" != "yes" ] && [ "${CONFIRM:-}" != "YES" ]; then
    echo "Restoration cancelled by user."
    exit 0
fi

# Portable Checksum & Write Helpers
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

# Safely read slice from eMMC device and calculate sha256 (handles SIGPIPE / pipefail and reads exact block count)
calc_emmc_hash() {
    local dev="$1"
    local offset_mb="$2"
    local size_bytes="$3"
    local bs_mb=1
    local count_blocks=$(( (size_bytes + 1048576 - 1) / 1048576 ))
    (
        set +e +o pipefail 2>/dev/null || true
        if [ "$offset_mb" -eq 0 ]; then
            dd if="$dev" bs=1M count="$count_blocks" 2>/dev/null | head -c "$size_bytes" | calc_stream_sha256
        else
            dd if="$dev" bs=1M skip="$offset_mb" count="$count_blocks" 2>/dev/null | head -c "$size_bytes" | calc_stream_sha256
        fi
    )
}

portable_write() {
    local in_file="$1"
    local out_dev="$2"
    local bs="$3"
    shift 3
    if [ "$OS_NAME" = "Darwin" ]; then
        dd if="$in_file" of="$out_dev" bs="$bs" conv=notrunc "$@" status=progress
        sync
    else
        dd if="$in_file" of="$out_dev" bs="$bs" conv=fdatasync,notrunc "$@" status=progress
        sync
    fi
}

RESTORED_COUNT=0
VERIFY_ERRORS=0

# Check for Full Dump image (emmc.img or mmcblk0.img)
FULL_IMG=""
if [ -f "$IMG_DIR/emmc.img" ]; then
    FULL_IMG="$IMG_DIR/emmc.img"
elif [ -f "$IMG_DIR/mmcblk0.img" ]; then
    FULL_IMG="$IMG_DIR/mmcblk0.img"
fi

if [ -n "$FULL_IMG" ]; then
    echo ""
    echo "➡️ Found full raw eMMC image: $FULL_IMG"
    echo "Writing full image to $EMMC_DEV..."
    portable_write "$FULL_IMG" "$EMMC_DEV" 4M
    echo ""
    
    echo "🔍 Verifying checksum for full image (this may take 1-2 minutes)..."
    IMG_SIZE=$(stat -c%s "$FULL_IMG" 2>/dev/null || stat -f%z "$FULL_IMG" 2>/dev/null)
    ORIG_HASH=$(calc_file_sha256 "$FULL_IMG")
    EMMC_HASH=$(calc_emmc_hash "$EMMC_DEV" 0 "$IMG_SIZE")
    
    if [ "$ORIG_HASH" = "$EMMC_HASH" ]; then
        echo "✅ Full image checksum verified OK!"
        echo "🎉 Full eMMC image restored successfully!"
        exit 0
    else
        echo "❌ CHECKSUM MISMATCH on full image restore!"
        echo "   Source: $ORIG_HASH"
        echo "   eMMC:   $EMMC_HASH"
        exit 1
    fi
fi

# Restore IDB image if present
if [ -f "$IMG_DIR/dm250-idb.img" ]; then
    echo ""
    echo "➡️ Restoring IDB (Image Definition Block) to sector 0..."
    portable_write "$IMG_DIR/dm250-idb.img" "$EMMC_DEV" 512 count=8192
    echo ""
    
    echo -n "🔍 Verifying dm250-idb.img... "
    ORIG_HASH=$(calc_file_sha256 "$IMG_DIR/dm250-idb.img")
    EMMC_HASH=$( (set +e +o pipefail 2>/dev/null || true; dd if="$EMMC_DEV" bs=512 count=8192 2>/dev/null | calc_stream_sha256) )
    if [ "$ORIG_HASH" = "$EMMC_HASH" ]; then
        echo "✅ OK"
    else
        echo "❌ CHECKSUM MISMATCH!"
        VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
    fi
    RESTORED_COUNT=$((RESTORED_COUNT + 1))
fi

# Function to get partition offset (in Megabytes, 1024*1024 bytes) - Bash 3.2 / macOS compatible
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

# Loop and restore partitions in ascending numerical order
for i in $(seq 1 27); do
    filename="mmcblk0p${i}.img"
    img_path="$IMG_DIR/$filename"
    if [ -f "$img_path" ]; then
        offset=$(get_part_offset "$filename")
        if [ -n "$offset" ]; then
            echo ""
            echo "➡️  [${i}/27] Restoring $filename to $EMMC_DEV at offset ${offset}MB..."
            portable_write "$img_path" "$EMMC_DEV" 1M seek="$offset"
            echo ""
            
            # Checksum Verification
            echo -n "   🔍 Verifying $filename checksum... "
            IMG_SIZE=$(stat -c%s "$img_path" 2>/dev/null || stat -f%z "$img_path" 2>/dev/null)
            ORIG_HASH=$(calc_file_sha256 "$img_path")
            EMMC_HASH=$(calc_emmc_hash "$EMMC_DEV" "$offset" "$IMG_SIZE")
            
            if [ "$ORIG_HASH" = "$EMMC_HASH" ]; then
                echo "✅ OK"
            else
                echo "❌ MISMATCH!"
                echo "      Original: $ORIG_HASH"
                echo "      On eMMC:  $EMMC_HASH"
                VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
            fi
            RESTORED_COUNT=$((RESTORED_COUNT + 1))
        fi
    fi
done

sync

echo ""
echo "=========================================================="
if [ "$RESTORED_COUNT" -eq 0 ]; then
    echo "⚠️ Error: No backup files (mmcblk0p*.img or emmc.img) found in '$IMG_DIR'."
    echo "Please place your backup files in '$IMG_DIR' or specify the directory as second argument."
    exit 1
elif [ "$VERIFY_ERRORS" -gt 0 ]; then
    echo "⚠️ Warning: Restoration finished with $VERIFY_ERRORS verify error(s)."
    echo "Please inspect the error logs above."
    exit 1
else
    echo "🎉 Restoration and Checksum Verification completed successfully!"
    echo "All $RESTORED_COUNT partition(s) were written and verified with 100% SHA256 match."
    echo "You can now safely disconnect the USB cable and reboot your Pomera!"
fi
echo "=========================================================="
