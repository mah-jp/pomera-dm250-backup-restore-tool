#!/bin/bash
# =====================================================================
# Pomera DM250 MaskROM Direct U-Boot UMS Launcher
# Uses xrock to send DDR init and U-Boot UMS directly over USB
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Pomera DM250 MaskROM UMS Boot Script ==="

# Check xrock binary
if [ ! -f "./xrock" ]; then
    echo "xrock binary not found. Building xrock first..."
    ./build_xrock.sh
fi

# Download required binaries if missing
if [ ! -f "rk3128_ddr_300MHz_v2.12.bin" ]; then
    echo "Downloading rk3128 DDR binary..."
    curl -L -o rk3128_ddr_300MHz_v2.12.bin https://jcs.org/dm250/rk3128_ddr_300MHz_v2.12.bin
fi

if [ ! -f "u-boot-ums.bin" ]; then
    echo "Downloading u-boot-ums binary..."
    curl -L -o u-boot-ums.bin https://jcs.org/dm250/u-boot-ums.bin
fi

echo "=========================================================="
echo "Connecting to Pomera in MaskROM mode..."
echo "Ensure Pomera is in MaskROM mode and connected via USB."
echo "=========================================================="

DEVICE_FOUND=0
if command -v lsusb >/dev/null 2>&1; then
    if lsusb | grep -qi "2207:310c"; then
        DEVICE_FOUND=1
    fi
elif [ "$(uname -s)" = "Darwin" ]; then
    if system_profiler SPUSBDataType 2>/dev/null | grep -qi "0x2207"; then
        DEVICE_FOUND=1
    fi
fi

if [ "$DEVICE_FOUND" -eq 0 ]; then
    echo "⚠️ Warning: Rockchip device in MaskROM mode (2207:310c) not detected."
    echo "Please ensure Pomera is connected in MaskROM mode."
    read -p "Press Enter to attempt upload anyway, or Ctrl+C to abort..."
fi

echo "Uploading DDR and U-Boot UMS to RAM..."
sudo ./xrock maskrom rk3128_ddr_300MHz_v2.12.bin u-boot-ums.bin

echo "=========================================================="
echo "🎉 U-Boot UMS sent! Pomera display should turn on and export eMMC."
echo "Check 'lsblk' or 'dmesg' to find the new block device (e.g. /dev/sdb)."
echo "=========================================================="
