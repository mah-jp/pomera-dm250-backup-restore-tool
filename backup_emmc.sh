#!/bin/bash
# =====================================================================
# Pomera DM250 Direct eMMC Backup / Dump Script
# Dumps eMMC raw image and/or individual partitions from Pomera to PC
# Cross-Platform Support: Linux & macOS
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

EMMC_DEV="${1:-}"
OUT_DIR_ARG="${2:-}"
DUMP_MODE="${3:-both}"
case "$DUMP_MODE" in
    both|raw|parts)
        ;;
    *)
        echo "⚠️ Unknown mode: $DUMP_MODE. Defaulting to 'both'."
        DUMP_MODE="both"
        ;;
esac

OS_NAME="$(uname -s)"

echo "=========================================================="
echo "  Pomera DM250 eMMC Direct Dump / Backup Tool"
echo "  Host Platform: $OS_NAME ($(uname -m))"
echo "=========================================================="

# Check for block device list helper
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

if [ -z "$EMMC_DEV" ] || [ "$EMMC_DEV" = "-h" ] || [ "$EMMC_DEV" = "--help" ]; then
    echo "Usage: sudo ./backup_emmc.sh <target_device> [output_directory] [mode]"
    echo ""
    echo "Arguments:"
    echo "  target_device     : Pomera eMMC device in UMS mode (Linux: /dev/sdb, macOS: /dev/rdiskN)"
    echo "  output_directory  : Directory to save backup images (default: ./backup_file)"
    echo "  mode              : Dump mode: 'both' (default), 'raw', or 'parts'"
    echo "                      - 'both'  : Full emmc.img (7.3GB) + separate p1~p27 images (Best for Stock King Jim OS)"
    echo "                      - 'raw'   : Full emmc.img (7.3GB) only (Best for OpenBSD / Linux & Fast Backup)"
    echo "                      - 'parts' : dm250-idb.img + p1~p27 images only (Legacy compatibility)"
    echo ""
    echo "💡 Best Practices:"
    echo "  - King Jim Stock OS : Use 'both' (default) to get both full raw dump and all 27 partitions."
    echo "  - OpenBSD / Linux   : Use 'raw' to dump the complete raw disk image (saves time & ~8GB PC disk space)."
    echo ""
    echo "Examples:"
    if [ "$OS_NAME" = "Darwin" ]; then
        echo "  # Stock Pomera Backup (Default: full raw image + 27 partitions)"
        echo "  sudo ./backup_emmc.sh /dev/rdisk2 ./factory_backup"
        echo ""
        echo "  # Custom OS (OpenBSD / Linux) Backup (Full raw disk image only)"
        echo "  sudo ./backup_emmc.sh /dev/rdisk2 ./custom_backup raw"
    else
        echo "  # Stock Pomera Backup (Default: full raw image + 27 partitions)"
        echo "  sudo ./backup_emmc.sh /dev/sdb ./factory_backup"
        echo ""
        echo "  # Custom OS (OpenBSD / Linux) Backup (Full raw disk image only)"
        echo "  sudo ./backup_emmc.sh /dev/sdb ./custom_backup raw"
    fi
    echo ""
    show_block_devices
    exit 1
fi

if [ ! -b "$EMMC_DEV" ] && [ ! -c "$EMMC_DEV" ]; then
    echo "⚠️ Error: '$EMMC_DEV' is not a valid block or character device."
    exit 1
fi

# Determine Output Directory
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_DIR="backup_file"
if [ -n "$OUT_DIR_ARG" ]; then
    OUT_DIR="$OUT_DIR_ARG"
fi

mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"

# Function to ensure output directory and files belong to real user (not root)
fix_ownership() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown -R "$SUDO_USER" "$OUT_DIR_ABS" 2>/dev/null || true
    fi
}
trap fix_ownership EXIT INT TERM
fix_ownership

echo "Destination Directory: $OUT_DIR_ABS"
echo "Dump Mode: $DUMP_MODE"
if [ "$DUMP_MODE" = "raw" ]; then
    echo "ℹ️  Mode 'raw': Dumping full raw eMMC image (emmc.img). Ideal for OpenBSD, Linux, or quick backups."
elif [ "$DUMP_MODE" = "both" ]; then
    echo "ℹ️  Mode 'both': Dumping full raw eMMC image + extracting 27 factory partitions + IDB."
elif [ "$DUMP_MODE" = "parts" ]; then
    echo "ℹ️  Mode 'parts': Extracting separate factory partitions + IDB only."
fi

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
        echo "🚨 WARNING: Target device size (${DEV_GB} GB) does not match expected Pomera eMMC size (~7.3GB / 8GB)!"
        echo "Please double check if '$EMMC_DEV' is REALLY the Pomera DM250."
        echo ""
    fi
fi

# Disk space check on PC
AVAIL_BYTES=""
if [ "$OS_NAME" = "Darwin" ]; then
    AVAIL_BYTES=$(df -k "$OUT_DIR_ABS" | awk 'NR==2 {print $4 * 1024}')
else
    AVAIL_BYTES=$(df -B1 "$OUT_DIR_ABS" | awk 'NR==2 {print $4}')
fi
AVAIL_GB=$(echo "scale=2; $AVAIL_BYTES / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "Unknown")
REQ_BYTES=8589934592 # ~8GB
if [ "$DUMP_MODE" = "both" ]; then
    REQ_BYTES=17179869184 # ~16GB
fi

echo "Available Disk Space on PC: ${AVAIL_GB} GB"

if [ -n "$AVAIL_BYTES" ] && [ "$AVAIL_BYTES" -lt "$REQ_BYTES" ]; then
    echo "⚠️ Warning: Low disk space on destination filesystem (${AVAIL_GB} GB available)."
    if [ "$AVAIL_BYTES" -lt 8000000000 ]; then
        echo "❌ Error: At least 8GB of free space is required to dump Pomera eMMC."
        exit 1
    fi
fi

echo "=========================================================="
echo "Ready to dump data from $EMMC_DEV to $OUT_DIR_ABS"
echo "=========================================================="
read -p "Start backup now? (Y/n): " CONFIRM
if [ "${CONFIRM:-}" = "n" ] || [ "${CONFIRM:-}" = "N" ]; then
    echo "Backup cancelled by user."
    exit 0
fi

START_TIME=$(date +%s)

# Partition offset and size lookup functions (in Megabytes, 1024*1024 bytes) - Bash 3.2 / macOS compatible
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
        "mmcblk0p27.img") echo 0 ;; # 0 means dump until end of device
        *) echo "" ;;
    esac
}

# Monitor background dump file size and print fraction progress, speed, elapsed, and ETA
monitor_dump_progress() {
    local target_pid="$1"
    local out_file="$2"
    local total_bytes="$3"
    local start_ts="$4"
    local total_mb=$(( (total_bytes + 1048575) / 1048576 ))

    while kill -0 "$target_pid" 2>/dev/null; do
        sleep 1
        local now=$(date +%s)
        local elapsed=$((now - start_ts))
        [ "$elapsed" -le 0 ] && continue

        local cur_bytes=$(stat -f%z "$out_file" 2>/dev/null || stat -c%s "$out_file" 2>/dev/null || echo 0)
        local cur_mb=$((cur_bytes / 1048576))

        if [ "$total_mb" -gt 0 ]; then
            local pct=$((cur_mb * 100 / total_mb))
            [ "$pct" -gt 100 ] && pct=100
            local speed_mb_s=$((cur_mb / elapsed))
            local remain_mb=$((total_mb > cur_mb ? total_mb - cur_mb : 0))
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
                "$cur_mb" "$total_mb" "$pct" "$speed_mb_s" "$el_m" "$el_s" "$eta_str"
        fi
    done
    wait "$target_pid" || true
    echo ""
}

# Step 1: Full RAW eMMC Dump (if mode is 'both' or 'raw')
if [ "$DUMP_MODE" = "both" ] || [ "$DUMP_MODE" = "raw" ]; then
    FULL_IMG="$OUT_DIR_ABS/emmc.img"
    echo ""
    echo "➡️ [Step 1] Dumping full raw eMMC image to: $FULL_IMG"
    echo "Reading from $EMMC_DEV (approx ${DEV_GB} GB)..."
    
    STEP1_START=$(date +%s)
    dd if="$EMMC_DEV" of="$FULL_IMG" bs=4M conv=sync,noerror status=none &
    DD_PID=$!
    
    TARGET_TOTAL_BYTES="${DEV_BYTES:-7818182656}"
    monitor_dump_progress "$DD_PID" "$FULL_IMG" "$TARGET_TOTAL_BYTES" "$STEP1_START"
    
    sync
    IMG_SIZE=$(stat -c%s "$FULL_IMG" 2>/dev/null || stat -f%z "$FULL_IMG" 2>/dev/null || echo "7.3GB")
    echo "✅ Full raw image dump completed: $FULL_IMG ($IMG_SIZE bytes)"
fi

# Step 2: Separate Partition Extraction (if mode is 'both' or 'parts')
if [ "$DUMP_MODE" = "both" ] || [ "$DUMP_MODE" = "parts" ]; then
    echo ""
    echo "➡️ [Step 2] Extracting IDB and separate partition images (mmcblk0p1 ~ mmcblk0p27)..."

    SRC_INPUT="$EMMC_DEV"
    if [ -f "$OUT_DIR_ABS/emmc.img" ]; then
        SRC_INPUT="$OUT_DIR_ABS/emmc.img"
        echo "⚡ Extracting partitions from local emmc.img for maximum speed..."
    else
        echo "Reading partitions directly from device $EMMC_DEV..."
    fi

    # Extract IDB (First 4MB / 8192 sectors)
    echo -n "   [IDB] Extracting dm250-idb.img (4MB)... "
    dd if="$SRC_INPUT" of="$OUT_DIR_ABS/dm250-idb.img" bs=512 count=8192 conv=sync,noerror status=none
    echo "✅ Done"

    # Extract partitions 1 through 27
    for i in $(seq 1 27); do
        filename="mmcblk0p${i}.img"
        offset=$(get_part_offset "$filename")
        size=$(get_part_size "$filename")
        
        if [ -n "$offset" ]; then
            out_file="$OUT_DIR_ABS/$filename"
            if [ "$size" -gt 0 ]; then
                echo -n "   [${i}/27] Extracting $filename (${size}MB at offset ${offset}MB)... "
                if [ "$SRC_INPUT" = "$EMMC_DEV" ] && [ "$size" -ge 64 ]; then
                    echo ""
                    part_start=$(date +%s)
                    dd if="$SRC_INPUT" of="$out_file" bs=1M skip="$offset" count="$size" conv=sync,noerror status=none &
                    part_pid=$!
                    monitor_dump_progress "$part_pid" "$out_file" "$((size * 1048576))" "$part_start"
                else
                    dd if="$SRC_INPUT" of="$out_file" bs=1M skip="$offset" count="$size" conv=sync,noerror status=none
                    echo "✅ Done"
                fi
            else
                echo -n "   [${i}/27] Extracting $filename (to end of device at offset ${offset}MB)... "
                if [ "$SRC_INPUT" = "$EMMC_DEV" ]; then
                    echo ""
                    part_start=$(date +%s)
                    dd if="$SRC_INPUT" of="$out_file" bs=1M skip="$offset" conv=sync,noerror status=none &
                    part_pid=$!
                    rem_est_bytes=657457152 # ~627MB remainder
                    monitor_dump_progress "$part_pid" "$out_file" "$rem_est_bytes" "$part_start"
                else
                    dd if="$SRC_INPUT" of="$out_file" bs=1M skip="$offset" conv=sync,noerror status=none
                    echo "✅ Done"
                fi
            fi
        fi
    done
    sync
    echo "✅ All 27 partition images + IDB extracted successfully!"
fi

# Step 3: Checksum Generation
echo ""
echo "➡️ [Step 3] Generating SHA256 Checksums (sha256sum.txt)..."
cd "$OUT_DIR_ABS"
rm -f sha256sum.txt

# Order files naturally: emmc.img, dm250-idb.img, mmcblk0p1.img ~ mmcblk0p27.img, then any others
HASH_FILES=()
for f in emmc.img mmcblk0.img dm250-idb.img; do
    [ -f "$f" ] && HASH_FILES+=("$f")
done
for i in $(seq 1 27); do
    [ -f "mmcblk0p${i}.img" ] && HASH_FILES+=("mmcblk0p${i}.img")
done
# Include any remaining .img files that weren't captured above
for f in *.img; do
    if [ -f "$f" ]; then
        already_added=0
        for existing in "${HASH_FILES[@]}"; do
            if [ "$f" = "$existing" ]; then
                already_added=1
                break
            fi
        done
        [ "$already_added" -eq 0 ] && HASH_FILES+=("$f")
    fi
done

for img in "${HASH_FILES[@]}"; do
    echo -n "   Hashing $img... "
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$img" >> sha256sum.txt
    else
        shasum -a 256 "$img" >> sha256sum.txt
    fi
    echo "✅"
done

# Step 4: Metadata Logging
echo ""
echo "➡️ [Step 4] Saving backup metadata (backup_info.txt)..."
cat << EOF > "$OUT_DIR_ABS/backup_info.txt"
Pomera DM250 Backup Information
========================================
Backup Date     : $(date +"%Y-%m-%d %H:%M:%S %Z")
Source Device   : $EMMC_DEV
Host Platform   : $OS_NAME ($(uname -m))
Device Size     : ${DEV_BYTES:-0} bytes (${DEV_GB} GB)
Dump Mode       : $DUMP_MODE
Toolkit Version : 2.0 (Pomera Unified Toolkit)

Partition Layout & Offsets (MB):
----------------------------------------
dm250-idb.img   : Offset 0 MB, Size 4 MB
mmcblk0p1.img   : Offset 8 MB, Size 8 MB
mmcblk0p2.img   : Offset 16 MB, Size 12 MB
mmcblk0p3.img   : Offset 28 MB, Size 6 MB (BSP Resource / DTB)
mmcblk0p4.img   : Offset 34 MB, Size 64 MB
mmcblk0p5.img   : Offset 98 MB, Size 512 MB
mmcblk0p6.img   : Offset 610 MB, Size 256 MB
mmcblk0p7.img   : Offset 866 MB, Size 1280 MB (User Storage)
mmcblk0p8.img   : Offset 2146 MB, Size 1024 MB (Dictionary)
mmcblk0p9.img   : Offset 3170 MB, Size 4 MB
mmcblk0p10.img  : Offset 3174 MB, Size 2 MB
mmcblk0p11.img  : Offset 3176 MB, Size 1 MB
mmcblk0p12.img  : Offset 3177 MB, Size 256 MB
mmcblk0p13.img  : Offset 3433 MB, Size 32 MB
mmcblk0p14.img  : Offset 3465 MB, Size 12 MB (Kernel)
mmcblk0p15.img  : Offset 3477 MB, Size 64 MB (Rootfs/Initramfs)
mmcblk0p16.img  : Offset 3541 MB, Size 12 MB
mmcblk0p17.img  : Offset 3553 MB, Size 6 MB
mmcblk0p18.img  : Offset 3559 MB, Size 64 MB
mmcblk0p19.img  : Offset 3623 MB, Size 512 MB
mmcblk0p20.img  : Offset 4135 MB, Size 256 MB
mmcblk0p21.img  : Offset 4391 MB, Size 4 MB
mmcblk0p22.img  : Offset 4395 MB, Size 256 MB
mmcblk0p23.img  : Offset 4651 MB, Size 256 MB
mmcblk0p24.img  : Offset 4907 MB, Size 2 MB
mmcblk0p25.img  : Offset 4909 MB, Size 1280 MB
mmcblk0p26.img  : Offset 6189 MB, Size 640 MB
mmcblk0p27.img  : Offset 6829 MB, Size Remainder (~627 MB)
EOF

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

# Restore directory/file ownership to regular user if run via sudo
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    chown -R "$SUDO_USER" "$OUT_DIR_ABS" 2>/dev/null || true
fi

echo ""
echo "=========================================================="
echo "🎉 Pomera eMMC Backup Completed Successfully!"
echo "   - Saved to       : $OUT_DIR_ABS"
echo "   - Time Elapsed   : ${MINUTES}m ${SECONDS}s"
echo "   - Checksums file : $OUT_DIR_ABS/sha256sum.txt"
echo "   - Metadata file  : $OUT_DIR_ABS/backup_info.txt"
echo "=========================================================="
echo "To restore this backup in the future, simply run:"
echo "  sudo ./restore_emmc.sh $EMMC_DEV $OUT_DIR_ABS"
echo "=========================================================="
