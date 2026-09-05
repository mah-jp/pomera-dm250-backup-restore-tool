#!/bin/bash
# =====================================================================
# Pomera DM250 Direct eMMC Restore Script (with Checksum Verification)
# Restores backup image files to the UMS-mounted eMMC disk
# Cross-Platform Support: Linux & macOS
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load shared utility library
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    # shellcheck source=common.sh
    source "$SCRIPT_DIR/common.sh"
else
    echo "❌ Error: common.sh not found in $SCRIPT_DIR"
    exit 1
fi

EMMC_DEV="${1:-}"
IMG_DIR_ARG="${2:-}"

# Temporary files and cleanup trap
TEMP_HASH_FILE="/tmp/emmc_verify_hash.$$"
cleanup() {
    rm -f "$TEMP_HASH_FILE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=========================================================="
echo "  Pomera DM250 eMMC Direct Restore Tool (with Verify)"
echo "  Host Platform: $OS_NAME ($(uname -m))"
echo "=========================================================="

if [ -z "$EMMC_DEV" ] || [ "$EMMC_DEV" = "-h" ] || [ "$EMMC_DEV" = "--help" ]; then
    echo "Usage: sudo ./restore_emmc.sh <target_device> [image_directory]"
    echo ""
    echo "Arguments:"
    echo "  target_device   : Pomera eMMC device in UMS mode (Linux: /dev/sdX, macOS: /dev/rdiskN)"
    echo "  image_directory : Directory containing backup images (default: ./restore_file)"
    echo ""
    echo "Examples:"
    if [ "$OS_NAME" = "Darwin" ]; then
        echo "  # Restore from default ./restore_file directory"
        echo "  sudo ./restore_emmc.sh /dev/rdiskN"
        echo ""
        echo "  # Restore from a specific backup directory"
        echo "  sudo ./restore_emmc.sh /dev/rdiskN ./backup_file"
    else
        echo "  # Restore from default ./restore_file directory"
        echo "  sudo ./restore_emmc.sh /dev/sdX"
        echo ""
        echo "  # Restore from a specific backup directory"
        echo "  sudo ./restore_emmc.sh /dev/sdX ./backup_file"
    fi
    echo ""
    show_block_devices
    if [ "$EMMC_DEV" = "-h" ] || [ "$EMMC_DEV" = "--help" ]; then
        exit 0
    fi
    exit 1
fi

if [ -n "$EMMC_DEV" ] && [ ! -e "$EMMC_DEV" ] && [ -e "/dev/$EMMC_DEV" ]; then
    EMMC_DEV="/dev/$EMMC_DEV"
fi

if [ ! -b "$EMMC_DEV" ] && [ ! -c "$EMMC_DEV" ]; then
    echo "⚠️ Error: '$EMMC_DEV' is not a valid block or character device."
    exit 1
fi

# Determine Image Directory (user specified argument OR default: ./restore_file)
IMG_DIR="restore_file"
if [ -n "$IMG_DIR_ARG" ]; then
    if [ -d "$IMG_DIR_ARG" ]; then
        IMG_DIR="$IMG_DIR_ARG"
    else
        echo "⚠️ Error: Specified directory '$IMG_DIR_ARG' does not exist."
        exit 1
    fi
fi

if [ ! -d "$IMG_DIR" ]; then
    echo "⚠️ Error: Restore image directory '$IMG_DIR' not found."
    echo "Please place your backup image files into './restore_file/' or specify the directory as second argument."
    exit 1
fi

echo "Source Image Directory: $IMG_DIR"

# Safety check: Block device size
DEV_BYTES=$(get_device_size_bytes "$EMMC_DEV")
DEV_GB=$(format_bytes_to_gb "$DEV_BYTES")

echo "Target Device: $EMMC_DEV (Size: approx ${DEV_GB} GB / ${DEV_BYTES:-0} bytes)"

# Warn if target is not ~7.3GB - 8.0GB
if [ -n "$DEV_BYTES" ] && [[ "$DEV_BYTES" =~ ^[0-9]+$ ]]; then
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

# Derive disk node for macOS unmounting (/dev/diskN)
EMMC_DISK_NODE="$(resolve_disk_node "$EMMC_DEV")"

# Automatically unmount any active partitions on the target device
unmount_target_device "$EMMC_DEV"

# Robust dd runner with auto-unmount and retry on Resource Busy (especially on macOS)
safe_dd_write() {
    local max_attempts=5
    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$OS_NAME" = "Darwin" ]; then
            diskutil unmountDisk "$EMMC_DISK_NODE" >/dev/null 2>&1 || true
        fi
        if "$@"; then
            return 0
        fi
        if [ "$OS_NAME" = "Darwin" ]; then
            echo "   ⚠️ Device busy/locked on macOS (attempt $attempt/$max_attempts), releasing locks..."
            sleep 1
            diskutil unmountDisk "$EMMC_DISK_NODE" >/dev/null 2>&1 || true
        else
            sleep 1
        fi
        attempt=$((attempt + 1))
    done
    echo "❌ Error: dd write failed after $max_attempts attempts."
    return 1
}

# Safely read slice from eMMC device and calculate sha256 (handles SIGPIPE / pipefail and reads exact block count)
calc_emmc_hash() {
    local dev="$1"
    local offset_mb="$2"
    local size_bytes="$3"
    (
        set +e +o pipefail 2>/dev/null || true
        if [ "$OS_NAME" = "Darwin" ]; then
            diskutil unmountDisk "$EMMC_DISK_NODE" >/dev/null 2>&1 || true
        fi
        # Optimize block size: use 4M blocks if offset is 4MB-aligned (especially full image at offset 0), fallback to 1M
        if [ "$offset_mb" -eq 0 ]; then
            local count_4m=$(( (size_bytes + 4194303) / 4194304 ))
            dd if="$dev" bs=4M count="$count_4m" 2>/dev/null | head -c "$size_bytes" | calc_stream_sha256
        elif [ $((offset_mb % 4)) -eq 0 ]; then
            local skip_4m=$((offset_mb / 4))
            local count_4m=$(( (size_bytes + 4194303) / 4194304 ))
            dd if="$dev" bs=4M skip="$skip_4m" count="$count_4m" 2>/dev/null | head -c "$size_bytes" | calc_stream_sha256
        else
            local count_1m=$(( (size_bytes + 1048575) / 1048576 ))
            dd if="$dev" bs=1M skip="$offset_mb" count="$count_1m" 2>/dev/null | head -c "$size_bytes" | calc_stream_sha256
        fi
    )
}

LAST_WRITE_SPEED_MB_S=0

chunk_write_with_progress() {
    local in_file="$1"
    local out_dev="$2"
    local base_offset_mb="${3:-0}"
    local chunk_mb=32
    
    local file_bytes=$(stat -f%z "$in_file" 2>/dev/null || stat -c%s "$in_file" 2>/dev/null || echo 0)
    local total_mb=$(( (file_bytes + 1048575) / 1048576 ))
    [ "$total_mb" -eq 0 ] && total_mb=1
    local total_chunks=$(( (total_mb + chunk_mb - 1) / chunk_mb ))
    local start_ts=$(date +%s)
    
    for c in $(seq 0 $((total_chunks - 1))); do
        local offset_in_file=$((c * chunk_mb))
        local count_mb=$chunk_mb
        if [ $((offset_in_file + count_mb)) -gt "$total_mb" ]; then
            count_mb=$((total_mb - offset_in_file))
        fi
        local target_seek_mb=$((base_offset_mb + offset_in_file))
        
        if [ "$OS_NAME" = "Darwin" ]; then
            safe_dd_write dd if="$in_file" of="$out_dev" bs=1M skip="$offset_in_file" seek="$target_seek_mb" count="$count_mb" conv=notrunc status=none
        else
            safe_dd_write dd if="$in_file" of="$out_dev" bs=1M skip="$offset_in_file" seek="$target_seek_mb" count="$count_mb" conv=fdatasync,notrunc status=none
        fi
        
        local written_mb=$((offset_in_file + count_mb))
        local now=$(date +%s)
        local elapsed=$((now - start_ts))
        local speed_mb_s=0
        [ "$elapsed" -gt 0 ] && speed_mb_s=$((written_mb / elapsed))
        
        local pct=$((written_mb * 100 / total_mb))
        [ "$pct" -gt 100 ] && pct=100
        local remain_mb=$((total_mb > written_mb ? total_mb - written_mb : 0))
        local eta_str="--:--"
        if [ "$speed_mb_s" -gt 0 ]; then
            local eta_sec=$((remain_mb / speed_mb_s))
            local eta_m=$((eta_sec / 60))
            local eta_s=$((eta_sec % 60))
            eta_str=$(printf "%02d:%02d" "$eta_m" "$eta_s")
        fi
        local el_m=$((elapsed / 60))
        local el_s=$((elapsed % 60))
        printf "\r   Progress: [ %d / %d MB ] (%d%%) | Speed: ~%d MB/s | Elapsed: %02d:%02d | ETA: ~%s" \
            "$written_mb" "$total_mb" "$pct" "$speed_mb_s" "$el_m" "$el_s" "$eta_str"
    done
    LAST_WRITE_SPEED_MB_S="$speed_mb_s"
    echo ""
}

portable_write() {
    local in_file="$1"
    local out_dev="$2"
    local bs="$3"
    local base_seek_mb="${4:-0}"
    
    local file_bytes=$(stat -f%z "$in_file" 2>/dev/null || stat -c%s "$in_file" 2>/dev/null || echo 0)
    local file_mb=$((file_bytes / 1048576))
    
    if [ "$file_mb" -ge 64 ]; then
        chunk_write_with_progress "$in_file" "$out_dev" "$base_seek_mb"
    else
        if [ "$base_seek_mb" -gt 0 ]; then
            if [ "$OS_NAME" = "Darwin" ]; then
                safe_dd_write dd if="$in_file" of="$out_dev" bs="$bs" seek="$base_seek_mb" conv=notrunc status=none
            else
                safe_dd_write dd if="$in_file" of="$out_dev" bs="$bs" seek="$base_seek_mb" conv=fdatasync,notrunc status=none
            fi
        else
            if [ "$OS_NAME" = "Darwin" ]; then
                safe_dd_write dd if="$in_file" of="$out_dev" bs="$bs" conv=notrunc status=none
            else
                safe_dd_write dd if="$in_file" of="$out_dev" bs="$bs" conv=fdatasync,notrunc status=none
            fi
        fi
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
    IMG_SIZE=$(stat -c%s "$FULL_IMG" 2>/dev/null || stat -f%z "$FULL_IMG" 2>/dev/null)
    IMG_MB=$((IMG_SIZE / 1048576))
    echo "Writing full image to $EMMC_DEV (${IMG_MB} MB)..."
    chunk_write_with_progress "$FULL_IMG" "$EMMC_DEV" 0
    echo ""
    
    echo "🔍 Verifying checksum for full image (reading from $EMMC_DEV with 4MB blocks)..."
    V_START=$(date +%s)
    ORIG_HASH=$(calc_file_sha256 "$FULL_IMG")
    
    (
        calc_emmc_hash "$EMMC_DEV" 0 "$IMG_SIZE" > "$TEMP_HASH_FILE" 2>/dev/null
    ) &
    HASH_PID=$!
    
    # Estimate read speed based on measured write speed (reads on USB 2.0 eMMC are typically >= write speed, approx 18-24 MB/s)
    est_speed_mb_s="${LAST_WRITE_SPEED_MB_S:-20}"
    if [ "$est_speed_mb_s" -lt 15 ]; then
        est_speed_mb_s=18
    fi
    
    while kill -0 "$HASH_PID" 2>/dev/null; do
        sleep 2
        NOW=$(date +%s)
        EL=$((NOW - V_START))
        EL_M=$((EL / 60))
        EL_S=$((EL % 60))
        EST_READ_MB=$((EL * est_speed_mb_s))
        [ "$EST_READ_MB" -gt "$IMG_MB" ] && EST_READ_MB="$IMG_MB"
        PCT=$((EST_READ_MB * 100 / IMG_MB))
        REMAIN_MB=$((IMG_MB > EST_READ_MB ? IMG_MB - EST_READ_MB : 0))
        ETA_SEC=$((REMAIN_MB / est_speed_mb_s))
        ETA_M=$((ETA_SEC / 60))
        ETA_S=$((ETA_SEC % 60))
        printf "\r   Verifying: [ ~%d / %d MB ] (~%d%%) | Est. Speed: ~%d MB/s | Elapsed: %02d:%02d | ETA: ~%02d:%02d" \
            "$EST_READ_MB" "$IMG_MB" "$PCT" "$est_speed_mb_s" "$EL_M" "$EL_S" "$ETA_M" "$ETA_S"
    done
    wait "$HASH_PID" || true
    echo ""
    
    EMMC_HASH=$(cat "$TEMP_HASH_FILE" 2>/dev/null || echo "")
    rm -f "$TEMP_HASH_FILE" 2>/dev/null
    
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
    if [ "$OS_NAME" = "Darwin" ]; then
        safe_dd_write dd if="$IMG_DIR/dm250-idb.img" of="$EMMC_DEV" bs=512 count=8192 conv=notrunc status=none
    else
        safe_dd_write dd if="$IMG_DIR/dm250-idb.img" of="$EMMC_DEV" bs=512 count=8192 conv=fdatasync,notrunc status=none
    fi
    echo ""
    
    echo -n "🔍 Verifying dm250-idb.img... "
    ORIG_HASH=$(calc_file_sha256 "$IMG_DIR/dm250-idb.img")
    EMMC_HASH=$( (set +e +o pipefail 2>/dev/null || true; [ "$OS_NAME" = "Darwin" ] && diskutil unmountDisk "$EMMC_DISK_NODE" >/dev/null 2>&1 || true; dd if="$EMMC_DEV" bs=512 count=8192 2>/dev/null | calc_stream_sha256) )
    if [ "$ORIG_HASH" = "$EMMC_HASH" ]; then
        echo "✅ OK"
    else
        echo "❌ CHECKSUM MISMATCH!"
        VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
    fi
    RESTORED_COUNT=$((RESTORED_COUNT + 1))
fi

# Calculate total size of all existing partition files for overall progress
TOTAL_RESTORE_BYTES=0
for i in $(seq 1 27); do
    p_img="$IMG_DIR/mmcblk0p${i}.img"
    if [ -f "$p_img" ]; then
        p_sz=$(stat -f%z "$p_img" 2>/dev/null || stat -c%s "$p_img" 2>/dev/null || echo 0)
        TOTAL_RESTORE_BYTES=$((TOTAL_RESTORE_BYTES + p_sz))
    fi
done
TOTAL_RESTORE_MB=$((TOTAL_RESTORE_BYTES / 1048576))

WRITTEN_RESTORE_BYTES=0
TOTAL_RESTORE_START=$(date +%s)

# Loop and restore partitions in ascending numerical order
for i in $(seq 1 27); do
    filename="mmcblk0p${i}.img"
    img_path="$IMG_DIR/$filename"
    if [ -f "$img_path" ]; then
        offset=$(get_part_offset "$filename")
        if [ -n "$offset" ]; then
            p_bytes=$(stat -f%z "$img_path" 2>/dev/null || stat -c%s "$img_path" 2>/dev/null || echo 0)
            p_mb=$((p_bytes / 1048576))
            
            echo ""
            echo "➡️  [${i}/27] Restoring $filename (${p_mb} MB) at offset ${offset}MB..."
            portable_write "$img_path" "$EMMC_DEV" 1M "$offset"
            
            WRITTEN_RESTORE_BYTES=$((WRITTEN_RESTORE_BYTES + p_bytes))
            WRITTEN_MB=$((WRITTEN_RESTORE_BYTES / 1048576))
            
            NOW=$(date +%s)
            ELAPSED=$((NOW - TOTAL_RESTORE_START))
            SPEED_MB_S=0
            [ "$ELAPSED" -gt 0 ] && SPEED_MB_S=$((WRITTEN_MB / ELAPSED))
            
            if [ "$TOTAL_RESTORE_MB" -gt 0 ]; then
                PCT=$((WRITTEN_MB * 100 / TOTAL_RESTORE_MB))
                [ "$PCT" -gt 100 ] && PCT=100
                REMAIN_MB=$((TOTAL_RESTORE_MB > WRITTEN_MB ? TOTAL_RESTORE_MB - WRITTEN_MB : 0))
                ETA_STR="--:--"
                if [ "$SPEED_MB_S" -gt 0 ]; then
                    ETA_SEC=$((REMAIN_MB / SPEED_MB_S))
                    ETA_M=$((ETA_SEC / 60))
                    ETA_S=$((ETA_SEC % 60))
                    ETA_STR=$(printf "%02d:%02d" "$ETA_M" "$ETA_S")
                fi
                EL_M=$((ELAPSED / 60))
                EL_S=$((ELAPSED % 60))
                echo "   Overall Write: [ ${WRITTEN_MB} / ${TOTAL_RESTORE_MB} MB ] (${PCT}%) | Speed: ~${SPEED_MB_S} MB/s | Elapsed: $(printf "%02d:%02d" "$EL_M" "$EL_S") | ETA: ~${ETA_STR}"
            fi
            
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
    echo "All $RESTORED_COUNT partition(s) were written and verified with valid SHA256 checksums."
    echo "You can now safely disconnect the USB cable and reboot your Pomera!"
fi
echo "=========================================================="
