#!/bin/bash
# =====================================================================
# Build script for xrock with custom progress display patch
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OS_NAME="$(uname -s)"
NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"

echo "=== Building custom xrock (with progress bar) ==="
echo "Host OS: $OS_NAME | Parallel jobs: $NPROC"

# Check build dependencies
echo "Checking dependencies..."
MISSING_DEPS=()
for cmd in git make gcc pkg-config; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done

if ! pkg-config --exists libusb-1.0 >/dev/null 2>&1; then
    MISSING_DEPS+=("libusb-1.0")
fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "⚠️ Error: Missing build dependencies: ${MISSING_DEPS[*]}"
    echo "Please install dependencies according to your OS:"
    if [ "$OS_NAME" = "Darwin" ]; then
        echo "  [macOS]: brew install libusb pkg-config git make gcc"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "  [Ubuntu/Debian]: sudo apt update && sudo apt install -y build-essential git libusb-1.0-0-dev pkg-config"
    elif command -v dnf >/dev/null 2>&1; then
        echo "  [Fedora]: sudo dnf install -y gcc make git libusb1-devel pkgconf-pkg-config"
    elif command -v pacman >/dev/null 2>&1; then
        echo "  [Arch]: sudo pacman -S --needed base-devel git libusb pkgconf"
    fi
    exit 1
fi

WORK_DIR="/tmp/xrock_build_$$"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "Cloning xrock repository..."
git clone --depth=1 https://github.com/xboot/xrock.git "$WORK_DIR"

echo "Applying progress display patch..."
if [ -f "$SCRIPT_DIR/patches/xrock_progress.patch" ]; then
    cd "$WORK_DIR"
    patch -p1 < "$SCRIPT_DIR/patches/xrock_progress.patch"
    cd "$SCRIPT_DIR"
fi

echo "Compiling xrock..."
cd "$WORK_DIR"
make -j"$NPROC"
cd "$SCRIPT_DIR"

cp "$WORK_DIR/xrock" ./xrock
chmod +x ./xrock
rm -rf "$WORK_DIR"

echo "=========================================================="
echo "🎉 xrock built successfully! Binary created at: ./xrock"
echo "=========================================================="
