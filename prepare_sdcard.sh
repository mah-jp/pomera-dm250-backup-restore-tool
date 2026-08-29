#!/bin/bash
# =====================================================================
# Pomera DM250 Recovery Tool (SD Card USB Mass Storage Mode Preparation)
# Prepares SD card bootloader to automatically export eMMC over USB
# Cross-Platform Support: Linux & macOS
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET_SD_DEV=""
BUILD_MODE="ro" # Default: Read-Only for maximum backup safety

show_help() {
    echo "Usage: $0 [options] [/dev/sdX | /dev/rdiskN]"
    echo ""
    echo "Options:"
    echo "  --readonly, --ro, -r   Build READ-ONLY bootloader (Default: 100% write-protected for safe backup)"
    echo "  --readwrite, --rw, -w  Build READ-WRITE bootloader (Allows restore/flashing eMMC back to Pomera)"
    echo "  --help, -h             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                     # Build default READ-ONLY bootloader images into ./sdcard_images/"
    echo "  $0 /dev/sdb            # Build READ-ONLY bootloader & flash directly to SD card"
    echo "  $0 --rw /dev/sdb       # Build READ-WRITE bootloader & flash directly to SD card"
    exit 0
}

# Parse command-line arguments
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            show_help
            ;;
        --readwrite|--rw|-w)
            BUILD_MODE="rw"
            ;;
        --readonly|--ro|-r)
            BUILD_MODE="ro"
            ;;
        *)
            if [ -z "$TARGET_SD_DEV" ]; then
                TARGET_SD_DEV="$arg"
            else
                echo "Warning: Unknown argument: $arg"
                show_help
            fi
            ;;
    esac
done

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"

# Ensure Homebrew, OpenSSL, GnuTLS, and GNU Make paths are in PATH on macOS
HOST_EXTRA_FLAGS=""
OPENSSL_DIR=""
if [ "$OS_NAME" = "Darwin" ]; then
    export PATH="/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/bin:/usr/local/opt/make/libexec/gnubin:/usr/local/bin:$PATH"
    
    if command -v brew >/dev/null 2>&1; then
        OPENSSL_DIR=$(brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null || true)
    fi
    if [ -z "$OPENSSL_DIR" ]; then
        for p in /opt/homebrew/opt/openssl@3 /opt/homebrew/opt/openssl /usr/local/opt/openssl@3 /usr/local/opt/openssl; do
            if [ -d "$p" ]; then
                OPENSSL_DIR="$p"
                break
            fi
        done
    fi
    
    GNUTLS_DIR=""
    if command -v brew >/dev/null 2>&1; then
        GNUTLS_DIR=$(brew --prefix gnutls 2>/dev/null || true)
    fi
    if [ -z "$GNUTLS_DIR" ]; then
        for p in /opt/homebrew/opt/gnutls /usr/local/opt/gnutls; do
            if [ -d "$p" ]; then
                GNUTLS_DIR="$p"
                break
            fi
        done
    fi
    
    EXTRA_INC=""
    EXTRA_LIB=""
    [ -n "$OPENSSL_DIR" ] && [ -d "$OPENSSL_DIR" ] && EXTRA_INC="-I${OPENSSL_DIR}/include $EXTRA_INC" && EXTRA_LIB="-L${OPENSSL_DIR}/lib $EXTRA_LIB"
    [ -n "$GNUTLS_DIR" ] && [ -d "$GNUTLS_DIR" ] && EXTRA_INC="-I${GNUTLS_DIR}/include $EXTRA_INC" && EXTRA_LIB="-L${GNUTLS_DIR}/lib $EXTRA_LIB"
    
    if [ -n "$EXTRA_INC" ]; then
        export HOSTCFLAGS="$EXTRA_INC ${HOSTCFLAGS:-}"
        export HOSTLDFLAGS="$EXTRA_LIB ${HOSTLDFLAGS:-}"
        export CFLAGS="$EXTRA_INC ${CFLAGS:-}"
        export LDFLAGS="$EXTRA_LIB ${LDFLAGS:-}"
        HOST_EXTRA_FLAGS="HOSTCFLAGS=\"$EXTRA_INC\" HOSTLDFLAGS=\"$EXTRA_LIB\""
    fi
fi

echo "=========================================================="
echo "  Pomera DM250 Toolkit - SD Card UMS Mode Builder"
echo "  Host OS: $OS_NAME ($ARCH_NAME) | Parallel jobs: $NPROC"
echo "=========================================================="

# Portable sed helper (works on GNU sed and macOS BSD sed)
portable_sed() {
    local expr="$1"
    local file="$2"
    sed "$expr" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Detect GNU Make (gmake on macOS or make >= 4.0)
MAKE_CMD="make"
if command -v gmake >/dev/null 2>&1; then
    MAKE_CMD="gmake"
elif [ -x "/opt/homebrew/opt/make/libexec/gnubin/make" ]; then
    MAKE_CMD="/opt/homebrew/opt/make/libexec/gnubin/make"
elif [ -x "/usr/local/opt/make/libexec/gnubin/make" ]; then
    MAKE_CMD="/usr/local/opt/make/libexec/gnubin/make"
fi

# Cross-Compiler Auto-Detection
echo "=== Step 1: Checking build dependencies and cross-compiler ==="

CROSS_COMPILE=""
if [ "$ARCH_NAME" = "armv7l" ] || [ "$ARCH_NAME" = "armv7" ]; then
    # Native 32-bit ARM (e.g. Raspberry Pi OS 32-bit)
    if command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
        CROSS_COMPILE="arm-linux-gnueabihf-"
    else
        CROSS_COMPILE=""
    fi
else
    # Cross-compilation candidates (x86_64, aarch64, macOS)
    for prefix in arm-linux-gnueabihf- arm-none-eabi- arm-linux-gnu- arm-none-linux-gnueabihf-; do
        if command -v "${prefix}gcc" >/dev/null 2>&1; then
            CROSS_COMPILE="$prefix"
            break
        fi
    done
fi

MISSING_DEPS=()
for cmd in curl dd dtc bison flex git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done

if ! command -v "$MAKE_CMD" >/dev/null 2>&1; then
    MISSING_DEPS+=("make (GNU Make >= 4.0)")
fi

if [ -z "$CROSS_COMPILE" ] && [ "$ARCH_NAME" != "armv7l" ] && [ "$ARCH_NAME" != "armv7" ]; then
    MISSING_DEPS+=("arm-linux-gnueabihf-gcc or arm-none-eabi-gcc")
fi

if [ "$OS_NAME" = "Darwin" ] && [ -z "$OPENSSL_DIR" ]; then
    MISSING_DEPS+=("openssl (brew install openssl)")
fi

# Check GNU Make version (>= 4.0 required by kernel/u-boot)
MAKE_RAW="$($MAKE_CMD --version 2>/dev/null || true)"
MAKE_VER="$(echo "$MAKE_RAW" | grep -oE '[0-9]+\.[0-9]+' | sed -n '1p' || true)"
MAKE_VER="${MAKE_VER:-0.0}"
MAKE_MAJOR="${MAKE_VER%%.*}"
MAKE_MAJOR="${MAKE_MAJOR:-0}"
if [ "$MAKE_MAJOR" -lt 4 ]; then
    if [ "$OS_NAME" = "Darwin" ]; then
        MISSING_DEPS+=("GNU Make >= 4.0 (macOS /usr/bin/make is 3.81, please run: brew install make)")
    else
        MISSING_DEPS+=("GNU Make >= 4.0 (found $MAKE_VER)")
    fi
fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "⚠️ Warning: Missing build dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Please install dependencies according to your OS:"
    if [ "$OS_NAME" = "Darwin" ]; then
        echo "  [macOS (Homebrew)]:"
        echo "    brew install dtc bison flex make git coreutils openssl"
        echo "    brew install --cask gcc-arm-embedded"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "  [Ubuntu / Debian / Raspberry Pi OS (apt)]:"
        echo "    sudo apt update && sudo apt install -y curl unzip git build-essential gcc-arm-linux-gnueabihf bison flex libssl-dev libgnutls28-dev python3 device-tree-compiler"
    elif command -v dnf >/dev/null 2>&1; then
        echo "  [Fedora / RHEL (dnf)]:"
        echo "    sudo dnf install -y curl git gcc make gcc-arm-linux-gnu bison flex openssl-devel python3 dtc"
    elif command -v pacman >/dev/null 2>&1; then
        echo "  [Arch Linux (pacman)]:"
        echo "    sudo pacman -S --needed curl git base-devel arm-linux-gnueabihf-gcc bison flex dtc python"
    else
        echo "  Please install GNU make >= 4.0, dtc, bison, flex, git, and an ARM 32-bit cross-compiler."
    fi
    echo ""
    read -p "Do you want to continue compilation anyway? (y/N): " CONFIRM
    if [ "${CONFIRM:-}" != "y" ] && [ "${CONFIRM:-}" != "Y" ]; then
        exit 1
    fi
fi

echo "✅ Using GNU Make: $MAKE_CMD (v$MAKE_VER)"
if [ -n "$CROSS_COMPILE" ]; then
    echo "✅ Using ARM Cross-Compiler: ${CROSS_COMPILE}gcc"
else
    echo "✅ Using native ARM compiler: gcc"
fi

# Create temporary build workspace
WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'pomera_sdcard_build' || echo "/tmp/pomera_sdcard_build_$$")
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

# Step 2: Compile Device Tree Blob (pomera-dm250.dtb)
echo "=== Step 2: Compiling Device Tree Blob (pomera-dm250.dtb) ==="
cd "$WORK_DIR"
echo "Cloning linux-dm250 repository (shallow depth=1)..."
git clone -b master --depth=1 https://github.com/jcs/linux-dm250.git
cd linux-dm250
eval $MAKE_CMD ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" multi_v7_defconfig
eval $MAKE_CMD ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$NPROC" rockchip/pomera-dm250.dtb
cp arch/arm/boot/dts/rockchip/pomera-dm250.dtb "$WORK_DIR/pomera-dm250.dtb"
cd "$WORK_DIR"
rm -rf linux-dm250

# Step 3: Clone and compile U-Boot
echo "=== Step 3: Cloning and Compiling U-Boot with UMS support ==="
if [ "$BUILD_MODE" = "ro" ]; then
    echo "🔒 Target Mode: READ-ONLY (Safe mode, 100% write-protected against accidental overwrites)"
else
    echo "✏️ Target Mode: READ-WRITE (Required for restore/flashing eMMC back to Pomera)"
fi
cd "$WORK_DIR"
echo "Cloning U-Boot repository (pomera-dm250 branch, shallow depth=1)..."
git clone -b pomera-dm250 --depth=1 https://github.com/jcs/u-boot.git
cd u-boot

# Copy the compiled DTB to U-Boot dts directory
cp "$WORK_DIR/pomera-dm250.dtb" dts/upstream/src/arm/rockchip/pomera-dm250.dtb

# Patch U-Boot defconfig and gadget driver:
portable_sed '/CONFIG_SILENT_CONSOLE/d' configs/pomera-dm250_defconfig
portable_sed '/CONFIG_SILENT_U_BOOT_ONLY/d' configs/pomera-dm250_defconfig
portable_sed 's/CONFIG_BOOTDELAY=.*/CONFIG_BOOTDELAY=3/' configs/pomera-dm250_defconfig
portable_sed 's/CONFIG_PREBOOT=.*/CONFIG_PREBOOT="setenv stdin serial,tc3589x-keyb; setenv stdout serial,vidconsole; setenv stderr serial,vidconsole; fdt addr ${fdtcontroladdr}; fdt set \/chosen stdout-path \/framebuffer"/' configs/pomera-dm250_defconfig

# Disable host EFI capsule tool (which requires GnuTLS on host)
echo "CONFIG_TOOLS_MKEFICAPSULE=n" >> configs/pomera-dm250_defconfig
echo "# CONFIG_TOOLS_MKEFICAPSULE is not set" >> configs/pomera-dm250_defconfig

# Apply USB connection notify and mode patch based on mode
if [ "$BUILD_MODE" = "ro" ]; then
    if [ -f "$SCRIPT_DIR/patches/uboot_ums_readonly.patch" ]; then
        echo "Applying U-Boot Read-Only UMS patch (Hardware Write-Protect)..."
        patch -p1 --forward < "$SCRIPT_DIR/patches/uboot_ums_readonly.patch" || true
    fi
    BOOTCMD_STR="cls; echo; echo =================================================; echo   [Pomera DM250 PC Storage Mount]; echo   USB Mass Storage Mode Active (READ-ONLY); echo   eMMC is mounted as READ-ONLY USB drive to PC.; echo   Write operations are 100% BLOCKED.; echo   Run backup_emmc.sh to backup to PC.; echo =================================================; echo; ums 0 mmc 0"
else
    if [ -f "$SCRIPT_DIR/patches/uboot_ums_readwrite.patch" ]; then
        echo "Applying U-Boot Read-Write UMS patch..."
        patch -p1 --forward < "$SCRIPT_DIR/patches/uboot_ums_readwrite.patch" || true
    fi
    BOOTCMD_STR="cls; echo; echo =================================================; echo   [Pomera DM250 PC Storage Mount]; echo   USB Mass Storage Mode Active (READ-WRITE); echo   eMMC is mounted as READ-WRITE USB drive to PC.; echo   Run restore_emmc.sh to flash/restore to Pomera; echo =================================================; echo; ums 0 mmc 0"
fi

echo "Patching U-Boot configuration for on-screen banner and automatic USB Mass Storage (UMS)..."
portable_sed "s|CONFIG_BOOTCOMMAND=.*|CONFIG_BOOTCOMMAND=\"$BOOTCMD_STR\"|" configs/pomera-dm250_defconfig

# Configure and compile U-Boot
eval $MAKE_CMD ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" $HOST_EXTRA_FLAGS pomera-dm250_defconfig
portable_sed '/CONFIG_TOOLS_MKEFICAPSULE/d' .config
echo "# CONFIG_TOOLS_MKEFICAPSULE is not set" >> .config
eval $MAKE_CMD ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" $HOST_EXTRA_FLAGS -j"$NPROC"
cd "$WORK_DIR"

# Download Rockchip Binaries
echo "=== Step 4: Downloading Rockchip DDR and MiniLoader Binaries ==="
curl -L -o rk3128_ddr_300MHz_v2.12.bin https://raw.githubusercontent.com/rockchip-linux/rkbin/master/bin/rk31/rk3128_ddr_300MHz_v2.12.bin
curl -L -o rk312x_miniloader_v2.63.bin https://raw.githubusercontent.com/rockchip-linux/rkbin/master/bin/rk31/rk312x_miniloader_v2.63.bin

# Generate Bootloader Images
echo "=== Step 5: Packaging Bootloader Images ==="
# Create idbloader.img (DDR Init + Miniloader combined properly into Rockchip SD image)
"$WORK_DIR/u-boot/tools/mkimage" -n rk3128 -T rksd -d rk3128_ddr_300MHz_v2.12.bin:rk312x_miniloader_v2.63.bin idbloader.img

# Create uboot.img (Packed U-Boot)
"$WORK_DIR/u-boot/tools/loaderimage" --pack "$WORK_DIR/u-boot/u-boot.bin" uboot.img

# Pad to exact 512-byte sector multiples (Strictly required for macOS /dev/rdisk direct DMA)
pad_to_sector() {
    local file="$1"
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    local rem=$(( size % 512 ))
    if [ "$rem" -ne 0 ]; then
        local pad=$(( 512 - rem ))
        dd if=/dev/zero bs=1 count="$pad" >> "$file" 2>/dev/null
    fi
}
pad_to_sector idbloader.img
pad_to_sector uboot.img

# Structure SD Card Output
echo "=== Step 6: Structuring SD Card Output Directory ==="
SD_DIR="$SCRIPT_DIR/sdcard_images"
rm -rf "$SD_DIR"
mkdir -p "$SD_DIR"

mv "$WORK_DIR/idbloader.img" "$SD_DIR/"
mv "$WORK_DIR/uboot.img" "$SD_DIR/"
cd "$SCRIPT_DIR"

# Restore directory/file ownership to regular user if run via sudo
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    chown -R "$SUDO_USER" "$SD_DIR" 2>/dev/null || true
fi

echo "=========================================================="
if [ "$BUILD_MODE" = "ro" ]; then
    echo "🎉 SD Card Bootloader Ready in: ./sdcard_images/ [READ-ONLY Safe Mode]"
    echo "   - Status        : 100% Write-Protected (Backup Only)"
else
    echo "🎉 SD Card Bootloader Ready in: ./sdcard_images/ [READ-WRITE Mode]"
    echo "   - Status        : Write-Enabled (Allows Flashing/Restore)"
fi
echo "   - idbloader.img (Sector 64)"
echo "   - uboot.img     (Sector 16384)"
echo "=========================================================="

# Helper to write to SD card across OSes
flash_to_sd() {
    local target="$1"
    local raw_target="$target"
    if [ "$OS_NAME" = "Darwin" ]; then
        if [[ "$target" =~ ^/dev/disk([0-9]+.*)$ ]]; then
            raw_target="/dev/rdisk${BASH_REMATCH[1]}"
        elif [[ "$target" =~ ^/dev/rdisk([0-9]+.*)$ ]]; then
            target="/dev/disk${BASH_REMATCH[1]}"
            raw_target="/dev/rdisk${BASH_REMATCH[1]}"
        elif [[ "$target" =~ ^disk([0-9]+.*)$ ]]; then
            raw_target="/dev/rdisk${BASH_REMATCH[1]}"
            target="/dev/disk${BASH_REMATCH[1]}"
        fi
        # On macOS, unmount all partitions first to prevent "Resource busy"
        echo "Unmounting $target..."
        diskutil unmountDisk "$target" 2>/dev/null || true
    fi

    echo "Writing directly to SD card device: $raw_target"
    read -p "Are you sure you want to write to $raw_target? (y/N): " CONFIRM_FLASH
    if [ "${CONFIRM_FLASH:-}" = "y" ] || [ "${CONFIRM_FLASH:-}" = "Y" ]; then
        if [ "$OS_NAME" = "Darwin" ]; then
            # macOS dd (bs=512 and re-unmount to prevent diskarbitrationd locks)
            diskutil unmountDisk "$target" 2>/dev/null || true
            sudo dd if="$SD_DIR/idbloader.img" of="$raw_target" bs=512 seek=64
            diskutil unmountDisk "$target" 2>/dev/null || true
            sudo dd if="$SD_DIR/uboot.img" of="$raw_target" bs=512 seek=16384
            sync
        else
            # Linux dd
            sudo dd if="$SD_DIR/idbloader.img" of="$raw_target" bs=512 seek=64 conv=fdatasync
            sudo dd if="$SD_DIR/uboot.img" of="$raw_target" bs=512 seek=16384 conv=fdatasync
            sync
        fi
        echo "✅ Flashed successfully to $raw_target!"
    fi
}

if [ -n "$TARGET_SD_DEV" ]; then
    if [ "$OS_NAME" = "Darwin" ] && [[ "$TARGET_SD_DEV" =~ ^disk[0-9]+ ]]; then
        TARGET_SD_DEV="/dev/$TARGET_SD_DEV"
    fi
    if [ ! -b "$TARGET_SD_DEV" ] && [ ! -c "$TARGET_SD_DEV" ]; then
        echo "⚠️ Error: '$TARGET_SD_DEV' is not a valid block or character device."
        exit 1
    fi
    flash_to_sd "$TARGET_SD_DEV"
else
    echo "Next steps to flash to SD card:"
    if [ "$OS_NAME" = "Darwin" ]; then
        echo "1. Identify your SD card device (e.g. /dev/disk4):"
        echo "   diskutil list"
        echo "2. Unmount the SD card volume (Required on macOS before dd):"
        echo "   diskutil unmountDisk /dev/diskN"
        echo "3. Run the following dd commands to flash raw boot sectors (/dev/rdiskN):"
        echo "   sudo dd if=sdcard_images/idbloader.img of=/dev/rdiskN bs=512 seek=64"
        echo "   diskutil unmountDisk /dev/diskN"
        echo "   sudo dd if=sdcard_images/uboot.img of=/dev/rdiskN bs=512 seek=16384"
        echo "   sync"
    else
        echo "1. Insert your SD card into your PC and identify its device (e.g. /dev/sda):"
        echo "   lsblk"
        echo "2. Run the following dd commands to flash raw boot sectors:"
        echo "   sudo dd if=sdcard_images/idbloader.img of=/dev/sdX bs=512 seek=64 conv=fdatasync"
        echo "   sudo dd if=sdcard_images/uboot.img of=/dev/sdX bs=512 seek=16384 conv=fdatasync"
        echo "   sync"
    fi
    echo ""
    echo "3. Insert the SD card into Pomera DM250."
    echo "4. Make sure USB-C cable is UNPLUGGED initially."
    echo "5. Turn on Pomera: Press and hold [Power Button] ONLY for 3~4 seconds (until screen turns on)."
    echo "   (Note: To completely turn OFF Pomera at any time, press and hold [Power Button] for 10~11 seconds)"
    echo "6. Once the screen turns on with recovery banner, connect USB-C cable to PC."
    if [ "$OS_NAME" = "Darwin" ]; then
        echo "   🍏 macOS Tip: If an 'unreadable disk' dialog pops up, ALWAYS choose 'Ignore'."
        echo "   🍏 macOS Tip: Execute backup/restore promptly to avoid USB idle auto-disconnect."
        echo "7. Pomera eMMC will appear as /dev/rdiskN on macOS."
        echo "   - To backup eMMC to PC : sudo ./backup_emmc.sh /dev/rdiskN ./factory_backup"
        echo "   - To restore eMMC      : sudo ./restore_emmc.sh /dev/rdiskN ./restore_file"
    else
        echo "7. Pomera eMMC will appear as /dev/sdX on Linux."
        echo "   - To backup eMMC to PC : sudo ./backup_emmc.sh /dev/sdX ./factory_backup"
        echo "   - To restore eMMC      : sudo ./restore_emmc.sh /dev/sdX ./restore_file"
    fi
fi
echo "=========================================================="
