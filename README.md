# Pomera DM250 Backup & Recovery Toolkit

[English](README.md) | [日本語](README.ja.md)

A toolkit for the **King Jim Pomera DM250** that enables internal eMMC backups to a PC and system restoration from saved backup images. By booting into **USB Mass Storage (UMS) mode via an SD card**, you can read and write the internal eMMC directly from your PC without hardware disassembly.

* **Supported Host OS**: Linux, macOS

---

## 💡 How It Works (Why SD Backup and Recovery Work)

The **Rockchip RK3128** SoC inside the Pomera DM250 features a hardware BootROM with the following built-in behavior:

1. **Storage Boot Priority**:
   * On power-on, the BootROM checks the **SD card slot (MMC1)** first. If a valid boot sector is found, it boots from the SD card instead of the internal eMMC (MMC0).
2. **Effortless SD Boot**:
   * Simply insert the prepared SD card and **press the Power button**. The maintenance bootloader (U-Boot) boots automatically. (Ejecting the SD card boots normal Pomera OS).
3. **USB Mass Storage (UMS) Integration**:
   * U-Boot running from the SD card exposes the internal eMMC to your PC as a **standard USB external drive (~7.3 GB)**.
   * From your PC, you can perform a **complete backup** or **restore the system from backup images**.

```
[Insert SD Card] ---> [Power ON Pomera] ---> [U-Boot (UMS Mode)] ---> [Connect USB to PC] ---> [Mounted as USB Disk]
                                                                                                    ├─► [Full PC Backup (backup_emmc.sh)]
                                                                                                    └─► [Restore/Flash to Pomera (restore_emmc.sh)]
```

---

## 🧰 Equipment & Prerequisites

### 1. Required Hardware
* **Pomera DM250** (with sufficient battery charge)
* **SD Card** (1 GB to 32 GB standard SD or microSD with adapter)
* **PC** (Linux or macOS)
* **USB Type-C Cable** (with data transfer capability)
* **Backup Files** (for restore only: `mmcblk0p*.img` or `emmc.img` backup of your Pomera)

### 2. PC Build Dependencies Installation

Install the required build tools and libraries for your operating system:

#### 🍏 macOS (Homebrew)
```bash
# Install build tools, DTC, ARM cross-compiler, and OpenSSL
brew install dtc bison flex make git coreutils libusb pkg-config openssl
brew install --cask gcc-arm-embedded
```

#### 🐧 Ubuntu / Debian / Raspberry Pi OS (apt)
```bash
sudo apt update
sudo apt install -y curl unzip git build-essential gcc-arm-linux-gnueabihf bison flex libssl-dev libgnutls28-dev python3 device-tree-compiler libusb-1.0-0-dev pkg-config
```

#### 🎩 Fedora / RHEL (dnf)
```bash
sudo dnf install -y curl git gcc make gcc-arm-linux-gnu bison flex openssl-devel python3 dtc libusb1-devel pkgconf-pkg-config
```

#### 🏹 Arch Linux (pacman)
```bash
sudo pacman -S --needed curl git base-devel arm-linux-gnueabihf-gcc bison flex dtc python libusb pkgconf
```

---

## 🚀 SD Card UMS Backup & Recovery Guide

### Step 1: Build the Recovery SD Bootloader
Run the following script to automatically compile and generate the U-Boot UMS binaries:

```bash
./prepare_sdcard.sh
```

* Upon completion, `idbloader.img` and `uboot.img` will be generated inside the `sdcard_images/` directory.
* (You can also specify the target drive directly to write in one step: `./prepare_sdcard.sh /dev/sdX` on Linux or `./prepare_sdcard.sh /dev/rdiskN` on macOS).

---

### Step 2: Write Raw Sectors to the SD Card
Insert the SD card into your PC and identify its device node:

* **Linux**: `lsblk` (e.g., `/dev/sdb` or `/dev/sdc`)
* **macOS**: `diskutil list` (e.g., `/dev/rdisk2` or `/dev/rdisk3`)

Write the bootloader directly to the raw sectors of the SD card using `dd`:

#### 🐧 Linux:
```bash
# Write IDB loader (DDR init + miniloader) to sector 64
sudo dd if=sdcard_images/idbloader.img of=/dev/sdX seek=64 conv=fdatasync

# Write U-Boot payload to sector 16384
sudo dd if=sdcard_images/uboot.img of=/dev/sdX seek=16384 conv=fdatasync

sync
```

#### 🍏 macOS:
```bash
# 1. Unmount all partitions on the SD card (required on macOS)
diskutil unmountDisk /dev/diskN

# 2. Write IDB loader to sector 64 (use /dev/rdiskN, bs=512)
sudo dd if=sdcard_images/idbloader.img of=/dev/rdiskN bs=512 seek=64

# 3. Unmount again to prevent macOS auto-mounting
diskutil unmountDisk /dev/diskN

# 4. Write U-Boot payload to sector 16384
sudo dd if=sdcard_images/uboot.img of=/dev/rdiskN bs=512 seek=16384

sync
```
*(Note: You do not need to format or copy files into the FAT partition. These images are written directly to raw sectors.)*

---

### Step 3: Boot Pomera and Connect to PC

1. Insert the prepared SD card into the Pomera DM250.
2. **Leave the USB cable disconnected.**
3. **Press and hold only the [Power Button] for 3–4 seconds** to turn on the device (when the SD card is inserted, it boots from the SD card automatically).
   * *(To force power off or perform a hard reset, **press and hold the Power Button for 10–11 seconds**).*
4. The backlight turns on, and the LCD displays the UMS startup banner (UMS mode launches automatically after a 3-second countdown):

```text
=================================================
  [Pomera DM250 PC Storage Mount]
  USB Mass Storage (UMS) Mode Active
  eMMC is mounted as a USB drive to PC.
  Run backup_emmc.sh (Backup) or restore_emmc.sh (Restore)
=================================================

UMS: LUN 0, dev 0, hwpart 0, sector 0x0, count 0x...
```

5. **Connect the Pomera to your PC with a USB Type-C cable.**
   * When the USB connection is established, an on-screen notification appears:
   ```text
   >>> [USB] Connected to Host PC (eMMC Ready) <<<
   ```

> [!IMPORTANT]
> **🍏 Critical Notes for macOS Users ("Ignore" Dialog & Auto-Suspend Prevention)**
> 1. **Always select "Ignore" on macOS disk dialog**:
>    * macOS will display a prompt: *"The disk you attached was not readable by this computer."*
>    * Choose **"Ignore"** (Selecting "Initialize" will overwrite/corrupt Pomera data; selecting "Eject" will disconnect the USB link).
> 2. **Run the script promptly after connecting**:
>    * Due to macOS power-saving behavior, leaving an unmounted USB device idle for tens of seconds triggers a USB suspend, causing Pomera to display `CTRL+C - Operation aborted` and exit UMS mode.
>    * Start `backup_emmc.sh` or `restore_emmc.sh` immediately after connecting USB and proceed past the confirmation prompt (`yes`) to initiate data transfer. Active transfer prevents suspension.

6. Confirm that the Pomera internal eMMC (~7.3 GB) is recognized as a block device on your PC:
   * **Linux**: `lsblk` (e.g., `/dev/sdb`)
   * **macOS**: `diskutil list` (e.g., `/dev/rdisk5`)

---

### Step 4-A: [Backup] Dump Pomera eMMC to PC (`backup_emmc.sh`)

Performs a read-only (100% safe) dump of the entire internal eMMC to your PC.
*(Replace `<target_device>` with your Pomera device identifier: **Linux: `/dev/sdX`**, **macOS: `/dev/rdiskN`**)*:

```bash
# [Stock King Jim OS Backup] (Default: Full RAW image + 27 partition images)
sudo ./backup_emmc.sh <target_device> ./factory_backup

# [Custom OS (OpenBSD / Linux) Backup] (raw mode: RAW full image only)
sudo ./backup_emmc.sh <target_device> ./custom_backup raw
```

#### 💡 Backup Mode Selection & Best Practices

`backup_emmc.sh` supports mode selection (`both` / `raw` / `parts`) via the 3rd argument:

| Mode | Saved Output | Recommended Use Case |
| :--- | :--- | :--- |
| **`both`**<br>(Default) | `emmc.img` (7.3 GB) +<br>`dm250-idb.img` + `mmcblk0p1.img`–`p27.img` | **Best for Stock King Jim OS**.<br>Saves the full raw image along with all 27 individual factory partitions extracted. |
| **`raw`** | `emmc.img` (7.3 GB) only | **Best for Custom OS (OpenBSD / Linux, etc.)**.<br>Custom OSes do not use the 27-partition layout. Saving only the full raw disk image is the fastest, cleanest approach and saves PC disk space (~8 GB). |
| **`parts`** | `dm250-idb.img` + `p1`–`p27.img` only | Saves only individual partitions (legacy compatibility). |

> [!TIP]
> **⚡ Backup Features & Specifications**
> * **Progress Bar & Real-time ETA**: Displays dynamic fraction progress, speed, elapsed time, and ETA.
> * **Automatic SHA256 Generation**: Automatically generates `sha256sum.txt` sorted in natural partition order.
> * **Metadata Logging**: Automatically records timestamps, device size, and sector boundaries in `backup_info.txt`.

---

### 🔄 [Advanced Technique] Effortless Dual-Boot Switching (Stock Pomera ⇄ Custom OS)

With this toolkit, you can switch between the factory Pomera firmware and custom OS environments (like OpenBSD or Linux) with complete confidence:

1. **Backup Factory Firmware**:
   ```bash
   sudo ./backup_emmc.sh <target_device> ./factory_backup both
   ```
2. **Install OpenBSD / Linux, configure your environment, and back it up**:
   ```bash
   sudo ./backup_emmc.sh <target_device> ./custom_backup raw
   ```
3. **Switch between environments with `restore_emmc.sh`**:
   ```bash
   # Restore Stock Pomera OS:
   sudo ./restore_emmc.sh <target_device> ./factory_backup

   # Switch back to Custom OS:
   sudo ./restore_emmc.sh <target_device> ./custom_backup
   ```
*(You have a 100% full-disk safety net, allowing safe OS experimentation at any time).*

---

### Step 4-B: [Restore] Flash Backup Back to Pomera (`restore_emmc.sh`)

Run the restore script from your PC *(Replace `<target_device>` with **Linux: `/dev/sdX`**, **macOS: `/dev/rdiskN`**)*:

```bash
# Default (Restore from images in ./restore_file/ directory)
sudo ./restore_emmc.sh <target_device>

# Restore from a specific backup directory
sudo ./restore_emmc.sh <target_device> ./factory_backup
```

* Automatically verifies target device size (~7.3 GB) to prevent accidental overwrites of host drives.
* Writes `mmcblk0p*.img` partitions or `emmc.img` sequentially.
* **Real-time SHA256 Verification**: Reads back each written partition immediately, compares hash sums against the source, and verifies data integrity (`✅ OK`) in real time down to the single bit.

> [!TIP]
> **⏱️ Real-time Progress & Verification**
> * **Progress Bar & Real-time ETA**: Dynamically calculates and displays remaining time during both write and verify operations.
> * **100% Safe Verification**: Reads back each partition immediately after write to verify SHA256 checksums match perfectly.

---

### Step 5: Completion & Reboot
1. When the terminal displays `🎉 Restoration completed successfully!`, the process is finished.
2. Disconnect the USB Type-C cable.
3. Eject the SD card.
4. Press and hold the Power button to power cycle the Pomera. It will boot into the restored operating system normally.

---

## ❓ Troubleshooting & FAQ

| Issue / Symptom | Cause & Solution |
| :--- | :--- |
| **macOS shows "The disk you attached was not readable" (Initialize / Eject / Ignore)** | • **Always click "Ignore"**.<br>• "Initialize" will destroy Pomera data; "Eject" will disconnect the USB drive. This warning is normal because the Pomera eMMC uses a non-standard Linux/Android partition layout that macOS cannot mount natively. |
| **Pomera LCD shows `CTRL+C - Operation aborted` and disconnects** | • Caused by macOS USB power-saving auto-suspend after idling on confirmation prompts.<br>• **Fix**: Hold Pomera power button 10–11s to turn OFF → hold 3–4s to turn ON. After connecting USB, immediately run `backup_emmc.sh` or `restore_emmc.sh` and type `yes` to begin transfer. |
| **How to force power off or boot from SD card** | • **Full Power OFF**: Press and hold the Power button for **10–11 seconds**.<br>• **Boot from SD**: Insert the SD card and hold the Power button for **3–4 seconds** (no other keys needed). |
| **`/dev/sdX` or `/dev/rdiskN` does not appear on PC after connecting USB** | • Powering on with the USB cable already plugged in may prevent UMS initialization. Follow the sequence: **"Power ON with USB unplugged → Wait for LCD banner → Connect USB"**.<br>• Check that the SD card is fully inserted. |
| **Reconnecting USB cable is not recognized** | • Due to Rockchip USB controller hardware characteristics, re-plugging USB while in UMS idle mode is not auto-detected. **Hold Power button 10–11s to turn OFF, then 3–4s to power on again.** |
| **Device does not power on / Screen stays black** | • Battery may be fully drained. Connect a USB charger and let it charge before retrying.<br>• Hold Power button for 10–11 seconds for hard reset, then try turning on again (3–4s). |
| **Size error in `restore_emmc.sh` or `backup_emmc.sh`** | • Ensure the specified target device node is the Pomera (~7.3 GB / 7,456 MB–8,000 MB) and not the host PC drive or SD card. |
| **Backup files not found during restore** | • Place `mmcblk0p1.img`–`mmcblk0p27.img` or `emmc.img` inside the `restore_file/` directory, or pass the backup directory path as an argument (e.g. `./restore_emmc.sh /dev/rdisk2 ./backup_file`). |

---

## 📁 Repository Contents & Scripts

* [`prepare_sdcard.sh`](./prepare_sdcard.sh): Automated build script for U-Boot UMS SD card bootloader
* [`backup_emmc.sh`](./backup_emmc.sh): Backup tool for dumping eMMC to PC (Full RAW & 27 individual partitions)
* [`restore_emmc.sh`](./restore_emmc.sh): Safe restore tool with real-time SHA256 read-back verification
* [`patches/uboot_usb_connect_notify.patch`](./patches/uboot_usb_connect_notify.patch): Patch for real-time USB connection status notifications on the Pomera LCD

---

## 🔗 References & Acknowledgments

* **Joshua Stein (jcs)**: [Installing OpenBSD on the Pomera DM250](https://jcs.org/2026/04/09/openbsd-dm250) (U-Boot/DDR port, UMS bootloader, hardware reverse engineering)
* **@ichinomoto**: [EKESETE.net](https://www.ekesete.net/log/?p=9504) (Pomera eMMC backup & restore scripts)

---

## 📜 License

This project is licensed under the [MIT License](LICENSE).
