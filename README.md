# Pomera DM250 Backup & Recovery Toolkit (ポメラ DM250 完全バックアップ＆復旧ツールキット)

本ツールキットは、**キングジム ポメラ DM250** の完全バックアップ（内蔵eMMCのPCへの保存）および、システム破損やブートローダー障害により起動不能（文鎮化）に陥った本体を、分解・改造することなく **SDカードブートおよび USB Mass Storage (UMS) モード** を経由して安全・確実に工場出荷状態やバックアップから復旧するためのクロスプラットフォーム対応ツールキット＆完全マニュアルです。

* **対応ホストOS**: Linux（Ubuntu / Debian / Fedora / Arch / Raspberry Pi OS 32bit・64bit / WSL2 等）および **macOS（Apple Silicon M1〜M4 / Intel）**
* **対応アーキテクチャ**: `x86_64`, `aarch64` (ARM64), `armhf` (ARM 32bit)

---

## 💡 仕組みの原理 (なぜ文鎮復旧や高速バックアップができるのか？)

ポメラ DM250 に搭載されている SoC（**Rockchip RK3128**）の BootROM には、ハードウェアレベルで以下の仕様が組み込まれています：

1. **ストレージ読み込みの優先順位**:
   * 電源投入時、BootROM はまず **SDカードスロット (MMC1)** を最優先で確認し、有効なブートセクタがあれば内蔵eMMC (MMC0) よりも優先してSDカードから起動します。
2. **手軽なSDブート**:
   * SDカードを挿入して **[電源ボタン] を押すだけ** で、SDカードに配置された保守用ブートローダー（U-Boot）が自動起動します（※SDカードを抜けば通常のポメラOSが起動します）。
3. **USB Mass Storage (UMS) 連携**:
   * SDカードから起動した U-Boot が、ポメラの内蔵eMMCを **USB外付けドライブ（約7.3GB）** としてPCに公開します。
   * これにより、PC側から **内蔵eMMCのデータをPCへ丸ごと高速バックアップ（約5〜8分）** したり、**バックアップイメージを直接書き戻して復旧（約25〜30分）** することができます。

```
[SDカード挿入] ---> [ポメラ電源ON] ---> [U-Boot (UMSモード)] ---> [PCとUSB接続] ---> [外付けUSBディスクとして認識]
                                                                                            ├─► [PCへ完全バックアップ (dump_emmc.sh)]
                                                                                            └─► [PCから書き戻し復旧 (restore_emmc.sh)]
```

---

## 🧰 必要な機材と事前準備

### 1. 必要な機材
* **ポメラ DM250**（バッテリーが極端に減っていない状態）
* **SDカード**（容量1GB〜32GB程度の標準SDまたはmicroSD+変換アダプタ）
* **PC**（Linux または macOS）
* **USB Type-C ケーブル**（データ転送対応）
* **バックアップファイル**（リストア時のみ：ご自身のポメラのバックアップ `mmcblk0p*.img` または `emmc.img`）

### 2. PC側のビルド依存パッケージの導入

ご利用のOSに合わせて、必要なツールをインストールしてください：

#### 🍏 macOS (Homebrew)
```bash
# ビルドツール・DTC・ARMクロスコンパイラ・OpenSSLの導入
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

## 🚀 SDカード UMS方式によるバックアップ＆復旧手順

### ステップ 1: リカバリ用SDブートローダーの生成
以下のスクリプトを実行して、U-Boot UMSバイナリを自動ビルド・生成します：

```bash
./prepare_sdcard.sh
```

※ 完了すると、`sdcard_images/` フォルダ内に `idbloader.img` と `uboot.img` が生成されます。
（直接SDカードへ書き込む場合は、`./prepare_sdcard.sh /dev/sdX` または macOSで `./prepare_sdcard.sh /dev/rdiskN` と指定することも可能です）

---

### ステップ 2: SDカードの生セクタへの書き込み
SDカードをPCに挿入し、デバイス名を確認します：

* **Linux**: `lsblk`（例: `/dev/sdb` や `/dev/sdc`）
* **macOS**: `diskutil list`（例: `/dev/rdisk2` や `/dev/rdisk3`）

確認したデバイス名に対して、以下のコマンドでブートセクタ領域に書き込みます：

#### 🐧 Linux の場合:
```bash
# セクタ 64 に IDBローダー（DDR初期化+ミニローダー）を書き込む
sudo dd if=sdcard_images/idbloader.img of=/dev/sdX seek=64 conv=fdatasync

# セクタ 16384 に U-Boot本体を書き込む
sudo dd if=sdcard_images/uboot.img of=/dev/sdX seek=16384 conv=fdatasync

sync
```

#### 🍏 macOS の場合:
```bash
# 1. SDカードのボリュームをアンマウント（macOSで必須）
diskutil unmountDisk /dev/diskN

# 2. セクタ 64 に IDBローダーを書き込む（/dev/rdiskN, bs=512 を指定）
sudo dd if=sdcard_images/idbloader.img of=/dev/rdiskN bs=512 seek=64

# 3. macOSの自動再マウントを防ぐため再度アンマウント
diskutil unmountDisk /dev/diskN

# 4. セクタ 16384 に U-Boot本体を書き込む
sudo dd if=sdcard_images/uboot.img of=/dev/rdiskN bs=512 seek=16384

sync
```
*(※ SDカードのFATフォーマット領域にファイルをコピーする必要はありません。生セクタへ直接書き込みます)*

---

### ステップ 3: ポメラの起動とPC接続

1. 作成したSDカードをポメラ DM250に挿入します。
2. **USBケーブルは抜いた状態**にします。
3. **[電源ボタン] のみを約3〜4秒間長押し**して電源を入れます（SDカード挿入時は電源ボタンのみの長押しで自動的にSDカードから最優先起動します）。
   * *(※ 電源を完全に切りたい・強制オフにしたい場合は、**[電源ボタン] を10〜11秒間長押し** してください)*
4. 画面バックライトが点灯し、ポメラの液晶画面に案内バナーが表示されます（※ 3秒間のカウントダウン後に自動でUMSモードが開始されます）：

```text
=================================================
  [Pomera DM250 PC Storage Mount]
  USB Mass Storage (UMS) Mode Active
  eMMC is mounted as a USB drive to PC.
  Run dump_emmc.sh (Backup) or restore_emmc.sh (Restore)
=================================================

UMS: LUN 0, dev 0, hwpart 0, sector 0x0, count 0x...
```

5. **USB Type-CケーブルでポメラとPCを接続**します。
   * 接続が確立されると、ポメラの画面上にリアルタイムで接続通知が表示されます：
   ```text
   >>> [USB] Connected to Host PC (eMMC Ready) <<<
   ```

> [!IMPORTANT]
> **🍏 macOS 接続時の重要な注意点（「無視」の選択と速やかな実行）**
> 1. **ダイアログは必ず「無視」を選択**:
>    * macOSに接続すると「セットしたディスクは、このコンピュータで読み取れないディスクでした。」というダイアログが表示されます。
>    * 選択肢（初期化 / 取り出す / 無視）のうち、必ず **「無視（Ignore）」** を選択してください（※「初期化」を選ぶとポメラ内部の全データが消去・破損します。「取り出す」を選ぶと接続が切断されます）。
> 2. **接続後は速やかにスクリプトを実行**:
>    * macOSの仕様上、未マウントのUSBデバイスに対してアクセスがないアイドル状態が数十秒続くと、macOS側のUSB省電力機能によりUSB接続が自動切断（サスペンド）され、ポメラ側で `CTRL+C - Operation aborted` となってUMSモードが終了してしまいます。
>    * USB接続後は時間を空けずに速やかに `dump_emmc.sh` または `restore_emmc.sh` を実行し、確認プロンプト（`yes`）を進めてデータ転送を開始してください（転送が始まれば切断されなくなります）。

6. PCのターミナルで確認し、ポメラ内蔵eMMCがストレージデバイス（約 7.3GB）として認識されていることを確認します：
   * **Linux**: `lsblk`（出力例: `/dev/sdb`）
   * **macOS**: `diskutil list`（出力例: `/dev/rdisk5`）

---

### ステップ 4-A: 【バックアップ取得】ポメラ eMMC を PC に保存 (`dump_emmc.sh`)

ポメラ側への書き込みを一切行わないリードオンリー（安全）動作で、PC側のストレージへ約5〜8分で丸ごと高速ダンプします：

```bash
# 【キングジム純正OSのバックアップ】（デフォルト: フルイメージ＋27パーティション分割を保存）
sudo ./dump_emmc.sh /dev/sdb ./factory_backup

# 【OpenBSD / Linux（非純正OS）のバックアップ】（fullモード: RAWフルイメージのみ保存）
sudo ./dump_emmc.sh /dev/sdb ./openbsd_backup full

# macOS の場合
sudo ./dump_emmc.sh /dev/rdisk5 ./factory_backup
```

#### 💡 バックアップモードの選び方とベストプラクティス

`dump_emmc.sh` は第3引数でモード（`all` / `full` / `partitions`）を指定できます：

| モード | 保存される内容 | 推奨用途・特徴 |
| :--- | :--- | :--- |
| **`all`**<br>(デフォルト) | `emmc.img` (7.3GB) ＋<br>`dm250-idb.img` ＋ `mmcblk0p1.img`〜`p27.img` | **キングジム純正OSに最適**。<br>全体のRAWイメージだけでなく、純正の27個のパーティションすべてを個別に切り出し保存します。 |
| **`full`** | `emmc.img` (7.3GB) のみ | **OpenBSD / Linux 等の非純正OSに最適**。<br>非純正OSは27パーティション構造ではないため、RAWフルイメージのみを丸ごと保存するのが最も高速で無駄がありません（PCの空き容量も約8GBで済みます）。 |
| **`partitions`** | `dm250-idb.img` ＋ `p1`〜`p27.img` のみ | 純正の個別パーティションのみを保存したい場合（レガシー互換用）。 |

> [!TIP]
> **⚡ 高速＆確実なバックアップ仕様**
> * **実効読込速度**: 約 **15 〜 25 MB/s**
> * **所要時間**: 約 **5 〜 8分**（7.3GBのRAWイメージを一括取得）
> * **SHA256 自動生成**: 取得したすべての `.img` ファイルに対して `sha256sum.txt` を自然順（パーティション番号順）で自動生成。
> * **メタデータ保存**: `backup_info.txt` に取得日時、デバイスサイズ、セクタ境界情報を自動記録。

---

### 🔄 【応用テクニック】「純正ポメラ」と「OpenBSD / Linux ポメラ」の二刀流切り替え

本ツールキットがあれば、ポメラ本体の環境を自由自在に行き来して運用することができます：

1. **工場出荷状態をバックアップ**:
   ```bash
   sudo ./dump_emmc.sh /dev/sdb ./factory_backup all
   ```
2. **OpenBSD や Linux をインストールして自分好みの環境を構築＆バックアップ**:
   ```bash
   sudo ./dump_emmc.sh /dev/sdb ./openbsd_backup full
   ```
3. **いつでも好きな方の環境へ `restore_emmc.sh` で一発復元**:
   ```bash
   # 純正ポメラに戻したい時（約25分で完全復元）
   sudo ./restore_emmc.sh /dev/sdb ./factory_backup

   # 再び OpenBSD ポメラに戻したい時（約25分で完全復元）
   sudo ./restore_emmc.sh /dev/sdb ./openbsd_backup
   ```
*(※ 完全なセーフティネットがあるため、OSの入れ替えや実験を何度でも安全に行えます)*

---

### ステップ 4-B: 【リストア復旧】バックアップをポメラに書き戻し

PC側でリストアスクリプトを実行します（※ デバイス名はステップ3で認識されたポメラのデバイス名）：

```bash
# Linux の場合
sudo ./restore_emmc.sh /dev/sdb

# macOS の場合
sudo ./restore_emmc.sh /dev/rdisk5

# バックアップフォルダを直接指定する場合
sudo ./restore_emmc.sh /dev/sdb ./restore_file
```

* スクリプトが自動的にデバイスサイズ（約7.3GB）を確認し、PC自身のディスク上書き等の誤操作を防止します。
* ディレクトリ内にある `mmcblk0p*.img` または `emmc.img` を順番に自動書き戻します。
* **SHA256 自動ベリファイ機能**: 各パーティションの書き込み直後に、eMMCからデータを読み戻してハッシュ値を照合し、1ビットの狂いもなく書き込めたか（`✅ OK`）をリアルタイムで自動検証します。

> [!TIP]
> **⏱️ 想定所要時間と転送速度の目安**
> * **実効書き込み速度**: 約 **4.8 〜 5.0 MB/s**
> * **ベリファイ（読み出し）速度**: 約 **15 〜 25 MB/s**
> * **全27パーティション（約7.3GB）の復元にかかる合計時間**: **約 25分 〜 30分**

---

### ステップ 5: 完了と再起動
1. ターミナルに `🎉 Restoration completed successfully!` と表示されたら完了です。
2. USBケーブルを抜きます。
3. SDカードを取り出します。
4. 電源ボタンを長押しして電源を入れ直すと、通常通りシステムが起動します。

---

## 🛠 【非常時用サブルート】MaskROM / USB直結復旧手順 (xrock方式)

万が一SDカードスロットが破損している場合や、SDブートすら受け付けない深刻な完全文鎮化状態の場合、PCからUSBケーブル経由で直接RAMにU-Boot UMSを転送して復旧することが可能です。

> [!NOTE]
> 通常のバックアップ・復元・OS入れ替えは、分解不要で確実な **メインルート（SDカード方式）** をご利用ください。本手順は非常時のエマージェンシールートです。

### 1. 改造版 xrock（進捗表示機能付き）のビルド
```bash
./build_xrock.sh
```

### 2. ポメラをMaskROMモードでPCに接続
* **完全文鎮化時**: 内蔵eMMCのブートローダーが消去または破損している場合、SDカードを挿さずに電源を入れると自動的にMaskROMモードで待機します。
* **強制投入時（ハードウェア）**: 裏蓋を開け、基板上の `TP501`（eMMCチップ横のテストポイント）をピンセット等でGNDにショートさせながら電源を入れます。
* PC側で `lsusb` を実行し、`2207:310c`（Rockchip Device in MaskROM mode）として見えていることを確認します。

### 3. USB経由でU-Boot UMSをRAMへロード
```bash
./boot_maskrom_ums.sh
```
* 送信が成功すると、ポメラの画面が点灯し、内蔵eMMCがPCにUSBドライブとしてマウントされます。
* あとはメインルートと同様に **バックアップ (`sudo ./dump_emmc.sh ...`)** または **書き戻し (`sudo ./restore_emmc.sh ...`)** を実行します。

---

## ❓ トラブルシューティング & 注意点

| 現象 | 原因と対策 |
| :--- | :--- |
| **macOSで「読み取れないディスク」「初期化/取り出す/無視」が出る** | ・**必ず「無視」を選択してください**。<br>・「初期化」を選ぶとポメラ内部の全データが消去・破損します。「取り出す」を選ぶと接続が切断されます。ポメラのeMMCはmacOS標準外のLinux/Android形式のため正常な警告です。 |
| **ポメラ画面に `CTRL+C - Operation aborted` と出て勝手に切断される** | ・macOSに接続後、確認プロンプトのまま数十秒放置されたため、macOSのUSB省電力機構（サスペンド）により切断されました。<br>・**対策**: ポメラの電源ボタンを10〜11秒長押しして完全OFF → 再度3〜4秒長押しで起動し、USB接続後は速やかにスクリプトを実行して確認プロンプト（`yes`）を進めてください。 |
| **電源の切り方・SDカードからの起動方法がわからない** | ・**完全電源OFF**: 電源ボタンを **10〜11秒間長押し**。<br>・**SDカードからの起動**: SDカードを挿入後、**電源ボタンのみを3〜4秒間長押し**（他のキーを押す必要はありません）。 |
| **PCにUSB接続しても `/dev/sdX`（`/dev/rdiskN`）が現れない** | ・USBケーブルを挿したまま電源を入れるとUMSが開始されない場合があります。**「USBを抜いた状態で電源ON → 画面点灯後にUSB挿入」** の順序を守ってください。<br>・SDカードが正しく奥まで挿入されているか確認してください。 |
| **USBケーブルを挿し直しても認識されない** | ・Rockchip USBコントローラのハードウェア仕様により、UMS待機中にケーブルを抜いた後の再挿入は自動認識されません。**一度ポメラの電源ボタンを10〜11秒長押ししてOFFにし、再度3〜4秒長押しして入れ直してください**。 |
| **電源が入らない・画面がつかない** | ・バッテリーが完全に放電している可能性があります。USB充電器にしばらく接続して充電してから再試行してください。<br>・電源ボタンを10〜11秒長押しして強制完全オフにしてから、再度3〜4秒長押しでお試しください。 |
| **`restore_emmc.sh` や `dump_emmc.sh` でサイズエラーが出る** | ・指定したデバイス名がPC本体のSSDやSDカード自身になっていないか確認してください。ポメラのeMMCは約7.3GB（7,456MB〜8,000MB）です。 |
| **バックアップファイルが見つからない** | ・`mmcblk0p1.img` 〜 `mmcblk0p27.img` または `emmc.img` を `restore_file/` や `backup_file/` ディレクトリに配置してください。 |

---

## 📁 スクリプト構成一覧

* [`prepare_sdcard.sh`](file:///home/mah/Dropbox/Documents/home/pomera/pomera_recovery-tool/prepare_sdcard.sh) : SDカード用 U-Boot UMS ブートローダー生成スクリプト（全プラットフォーム対応）
* [`dump_emmc.sh`](file:///home/mah/Dropbox/Documents/home/pomera/pomera_recovery-tool/dump_emmc.sh) : UMSマウントされたeMMCからPCへ完全バックアップ（フルRAW & 27パーティション）を取得するスクリプト
* [`restore_emmc.sh`](file:///home/mah/Dropbox/Documents/home/pomera/pomera_recovery-tool/restore_emmc.sh) : UMSマウントされたeMMCへの安全なdd書き戻し＆自動検証スクリプト
* [`build_xrock.sh`](file:///home/mah/Dropbox/Documents/home/pomera/pomera_recovery-tool/build_xrock.sh) : プログレスバー付き `xrock` ビルドスクリプト（macOS/Linux対応）
* [`boot_maskrom_ums.sh`](file:///home/mah/Dropbox/Documents/home/pomera/pomera_recovery-tool/boot_maskrom_ums.sh) : MaskROMモード直接起動用スクリプト
* [`patches/xrock_progress.patch`](file:///home/mah/Dropbox/Documents/home/pomera/pomera_recovery-tool/patches/xrock_progress.patch) : xrock用転送進捗表示パッチ
* [`patches/uboot_usb_connect_notify.patch`](file:///home/mah/Dropbox/Documents/home/pomera/pomera_recovery-tool/patches/uboot_usb_connect_notify.patch) : U-Boot画面用USB接続状態通知パッチ

---

## 🔗 参考リンク・謝辞

* **Joshua Stein (jcs)**: [Installing OpenBSD on the Pomera DM250](https://jcs.org/2026/04/09/openbsd-dm250) (U-Boot/DDR移植、UMSブートローダー、ハードウェア解析)
* **@ichinomoto 氏**: [EKESETE.net](https://www.ekesete.net/log/?p=9504) (ポメラeMMCバックアップ・リストアスクリプト)
* **xboot/xrock**: [xrock GitHub Repository](https://github.com/xboot/xrock) (Rockchip MaskROM/USBツール)
