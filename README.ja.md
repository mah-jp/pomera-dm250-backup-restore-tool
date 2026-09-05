# Pomera DM250 Backup & Restore Tool (Pomera DM250 バックアップ＆復元ツール)

[English](README.md) | [日本語](README.ja.md)

本ツールは、**キングジム Pomera DM250** の内蔵eMMCをPCへバックアップしたり、保存したバックアップイメージから本体を書き戻して復元するためのツールです。本体を分解することなく、**SDカードブートによる USB Mass Storage (UMS) モード** を経由してPCからeMMCの読み書きを行います。

* **対応ホストOS**: Linux, macOS

---

## 💡 仕組みの原理 (なぜバックアップや復元ができるのか？)

Pomera DM250 に搭載されている SoC（**Rockchip RK3128**）の BootROM には、ハードウェアレベルで以下の仕様が組み込まれています：

1. **ストレージ読み込みの優先順位**:
   * 電源投入時、BootROM はまず **SDカードスロット (MMC1)** を最優先で確認し、有効なブートセクタがあれば内蔵eMMC (MMC0) よりも優先してSDカードから起動します。
2. **手軽なSDブート**:
   * SDカードを挿入して **[電源ボタン] を押すだけ** で、SDカードに配置された保守用ブートローダー（U-Boot）が自動起動します（※SDカードを抜けば通常の Pomera OS が起動します）。
3. **USB Mass Storage (UMS) 連携**:
   * SDカードから起動した U-Boot が、Pomera の内蔵eMMCを **USB外付けドライブ（約7.3GB）** としてPCに公開します。
   * これにより、PC側から **内蔵eMMCのデータをPCへ丸ごとバックアップ** したり、**バックアップイメージを直接書き戻して復元** することができます。

```
[SDカード挿入] ---> [Pomera電源ON] ---> [U-Boot (UMSモード)] ---> [PCとUSB接続] ---> [外付けUSBディスクとして認識]
                                                                                             ├─► [PCへ完全バックアップ (backup_emmc.sh)]
                                                                                             └─► [PCから書き戻し復元 (restore_emmc.sh)]
```

---

## 🧰 必要な機材と事前準備

### 1. 必要な機材
* **Pomera DM250**（バッテリーが極端に減っていない状態）
* **SDカード**（容量1GB〜32GBの標準SDまたはmicroSD+変換アダプタ）
* **PC**（Linux または macOS）
* **USB Type-C ケーブル**（データ転送対応）
* **バックアップファイル**（リストア時のみ：ご自身の Pomera のバックアップ `emmc.img`、または `dm250-idb.img` ＋ `mmcblk0p1.img`〜`mmcblk0p27.img`）

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

## 🚀 SDカード UMS方式によるバックアップ＆復元手順

### ステップ 1: SDカードの作成（ビルド＆書き込み）

SDカードをPCに挿入し、以下のスクリプトを実行します。
必要なブートローダーの自動ビルドから、接続されたSDカードへの生セクタ書き込みまで**対話形式（全自動）で完了**します：

```bash
# 【通常（バックアップ推奨）: 安全な Read-Only モード】
# PCからの誤書き込み・上書きを物理ブロックする安全モードです。
./prepare_sdcard.sh

# 【復元時のみ: 書き込み許可 Read-Write モード】
# ポメラ内蔵eMMCへのデータ書き戻し（リストア）を行いたい場合はこちらを指定します。
./prepare_sdcard.sh --readwrite
```

#### 実行の流れ（自動完結）:
1. スクリプトが自動で U-Boot UMS ブートローダーをコンパイルします。
2. 完了後、PCに接続されている外部ディスク（SDカード等）を自動検出し、候補を表示して入力を求めます：
   ```text
   Available External Disks (macOS):
   /dev/disk4 (external, physical): ...

   Enter target SD card device (e.g. /dev/rdiskN or diskN) or press Enter to skip: /dev/rdisk4
   ```
3. 表示されたデバイス名（例: macOS なら `/dev/rdisk4` や `disk4`、Linux なら `/dev/sdX`）を入力すると、自動でアンマウントを行い、最終確認プロンプト（`yes`）を経てブートセクタ領域への書き込みが安全に完了します。
   *(※ 事前にデバイス名が分かっている場合は、`./prepare_sdcard.sh /dev/rdisk4` のように引数に指定してワンライナーで作成することも可能です)*

> [!TIP]
> **🛡️ 安全第一の Read-Only（読み取り専用）デフォルト仕様**
> * 通常の `./prepare_sdcard.sh` を実行すると、**ハードウェアライトプロテクト（書き込み禁止）** が有効化されたブートローダーが生成・書き込まれます。
> * これにより、PC側で誤って `dd` 上書きを実行したり、macOSで誤って「初期化」を押しても、**Pomera 側が書き込みを物理ブロックするため本体データは一切破損しません**。
> * Pomera へバックアップを書き戻す（復元する）時のみ、`--readwrite`（または `--rw`）を指定して SD カードを作成してください。

<details>
<summary><b>💡 【手動で書き込みたい場合（オプション / 上級者向け）】</b></summary>

スクリプト実行時のデバイス入力プロンプトで何も入力せず Enter キーを押すと、SDカードへの自動書き込みをスキップし、`sdcard_images/` フォルダ内にイメージファイル（`idbloader.img`, `uboot.img`）のみを生成して終了します。

自前で `dd` コマンドを使って生セクタへ手動書き込みを行いたい場合は、以下のコマンドを実行してください：

##### 🐧 Linux の場合:
```bash
# セクタ 64 に IDBローダー（DDR初期化+ミニローダー）を書き込む
sudo dd if=sdcard_images/idbloader.img of=/dev/sdX seek=64 conv=fdatasync

# セクタ 16384 に U-Boot本体を書き込む
sudo dd if=sdcard_images/uboot.img of=/dev/sdX seek=16384 conv=fdatasync

sync
```

##### 🍏 macOS の場合:
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

</details>

---

### ステップ 2: Pomera の起動とPC接続

1. 作成したSDカードを Pomera DM250 に挿入します。
2. **USBケーブルは抜いた状態**にします。
3. **[電源ボタン] のみを約3〜4秒間長押し**して電源を入れます（SDカード挿入時は電源ボタンのみの長押しで自動的にSDカードから最優先起動します）。
   * *(※ 電源を完全に切りたい・強制オフにしたい場合は、**[電源ボタン] を10〜11秒間長押し** してください)*
4. 画面バックライトが点灯し、Pomera の液晶画面にモードに応じた案内バナーが表示されます（※ 3秒間のカウントダウン後に自動でUMSモードが開始されます）：

```text
=================================================
  [Pomera DM250 PC Storage Mount]
  USB Mass Storage Mode Active (READ-ONLY)
  eMMC is mounted as READ-ONLY USB drive to PC.
  Write operations are blocked.
  Run backup_emmc.sh to backup to PC.
=================================================

UMS: LUN 0, dev 0, hwpart 0, sector 0x0, count 0x...
```

5. **USB Type-Cケーブルで Pomera と PC を接続**します。
   * 接続が確立されると、Pomera の画面上にリアルタイムで接続通知が表示されます：
   ```text
   >>> [USB] Connected to Host PC (eMMC Ready) <<<
   ```

> [!IMPORTANT]
> **🍏 macOS 接続時の重要な注意点（「無視」の選択と速やかな実行）**
> 1. **ダイアログは必ず「無視」を選択**:
>    * macOSに接続すると「セットしたディスクは、このコンピュータで読み取れないディスクでした。」というダイアログが表示されることがあります。
>    * 選択肢（初期化 / 取り出す / 無視）のうち、必ず **「無視（Ignore）」** を選択してください（※「初期化」を選ぶと Pomera 内部の全データが消去・破損します。「取り出す」を選ぶと接続が切断されます）。
> 2. **手動アンマウントは不要（スクリプトが自動アンマウント）**:
>    * Pomera内のパーティション（FAT等）がデスクトップに自動マウントされた場合でも、手動でアンマウント操作を行う必要はありません。スクリプト（`restore_emmc.sh` / `backup_emmc.sh`）が実行時に自動で全パーティションをアンマウントします。
> 3. **接続後は速やかにスクリプトを実行**:
>    * macOSの仕様上、未アクセスのUSBデバイスのアイドル状態が続くと省電力機能によりUSB接続が自動切断（サスペンド）され、Pomera側で `CTRL+C - Operation aborted` となってUMSモードが終了してしまいます。
>    * USB接続後は手動操作に時間をかけず、速やかに `backup_emmc.sh` または `restore_emmc.sh` を実行して確認プロンプト（`yes`）を進めてください（転送が始まれば切断されなくなります）。

6. PCのターミナルで確認し、Pomera 内蔵eMMCがストレージデバイス（約 7.3GB）として認識されていることを確認します：
   * **Linux**: `lsblk`（確認例: `/dev/sdX`）
   * **macOS**: `diskutil list external`（確認例: `/dev/rdiskN`）

---

### ステップ 3-A: 【バックアップ取得】Pomera eMMC を PC に保存 (`backup_emmc.sh`)

Pomera 側への書き込みを一切行わないリードオンリー（安全）動作で、PC側のストレージへ丸ごとダンプします。
※ `<target_device>` には、ステップ2で確認した Pomera のデバイス名（**Linux: `/dev/sdX`**、**macOS: `/dev/rdiskN`**）を指定します。

```bash
# 【キングジム純正OSのバックアップ】（デフォルト: フルイメージ＋27パーティション分割を保存）
sudo ./backup_emmc.sh <target_device> ./factory_backup

# 【カスタムOS（OpenBSD / Linux 等）のバックアップ】（rawモード: RAWフルイメージのみ保存）
sudo ./backup_emmc.sh <target_device> ./custom_backup raw
```

#### 💡 バックアップモードの選び方とベストプラクティス

`backup_emmc.sh` は第3引数でモード（`both` / `raw` / `parts`）を指定できます：

| モード | 保存される内容 | 推奨用途・特徴 |
| :--- | :--- | :--- |
| **`both`**<br>(デフォルト) | `emmc.img` (7.3GB) ＋<br>`dm250-idb.img` ＋ `mmcblk0p1.img`〜`p27.img` | **キングジム純正OSに最適**。<br>全体のRAWイメージだけでなく、純正の27個のパーティションすべてを個別に切り出し保存します。 |
| **`raw`** | `emmc.img` (7.3GB) のみ | **カスタムOS（OpenBSD / Linux 等）に最適**。<br>カスタムOSは27パーティション構造ではないため、RAWフルイメージのみを丸ごと保存するのが最もスムーズで無駄がありません（PCの空き容量も約8GBで済みます）。 |
| **`parts`** | `dm250-idb.img` ＋ `p1`〜`p27.img` のみ | 純正の個別パーティションのみを保存したい場合（レガシー互換用）。 |

> [!TIP]
> **⚡ バックアップ仕様と特徴**
> * **プログレス表示 & ETA 予測**: 転送中の実測速度に基づき、リアルタイムに進捗分数と残り予測時間を自動表示。
> * **SHA256 自動生成**: 取得したすべての `.img` ファイルに対して `sha256sum.txt` を自然順（パーティション番号順）で自動生成。
> * **メタデータ保存**: `backup_info.txt` に取得日時、デバイスサイズ、セクタ境界情報を自動記録。

---

### 🔄 【応用テクニック】「純正 Pomera」と「カスタムOS（OpenBSD / Linux 等）」の二刀流切り替え

本ツールがあれば、Pomera 本体の環境を自由自在に行き来して運用することができます：

1. **工場出荷状態をバックアップ**:
   ```bash
   sudo ./backup_emmc.sh <target_device> ./factory_backup both
   ```
2. **OpenBSD や Linux 等のカスタム環境を構築＆バックアップ**:
   ```bash
   sudo ./backup_emmc.sh <target_device> ./custom_backup raw
   ```
3. **いつでも好きな方の環境へ `restore_emmc.sh` で一発復元**:
   ```bash
   # 純正 Pomera に戻したい時
   sudo ./restore_emmc.sh <target_device> ./factory_backup

   # 再びカスタムOS環境に戻したい時
   sudo ./restore_emmc.sh <target_device> ./custom_backup
   ```

---

### ステップ 3-B: 【リストア復元】バックアップを Pomera に書き戻し (`restore_emmc.sh`)

> [!IMPORTANT]
> **⚠️ リストア時の注意: Read-Write モードの SD カードが必要です**
> デフォルトで作成された SD カードは **Read-Only（書き込み禁止）** になっています。
> リストア（復元・書き戻し）を行う際は、あらかじめ **`./prepare_sdcard.sh --readwrite`（または `--rw`）** で書き込みを許可した SD カードを作成・挿入して Pomera を起動してください。

PC側でリストアスクリプトを実行します（※ `<target_device>` には **Linux: `/dev/sdX`**、**macOS: `/dev/rdiskN`** を指定）：

```bash
# デフォルト（./restore_file/ ディレクトリ内のイメージから復元）
sudo ./restore_emmc.sh <target_device>

# バックアップフォルダを直接指定して復元する場合
sudo ./restore_emmc.sh <target_device> ./factory_backup
```

* スクリプトが自動的にデバイスサイズ（約7.3GB）を確認し、PC自身のディスク上書き等の誤操作を防止します。
* ディレクトリ内にある `emmc.img`、または `dm250-idb.img` と各個別パーティション（`mmcblk0p*.img`）を自動検知して書き戻します。
* **SHA256 自動ベリファイ機能**: 各パーティションの書き込み直後に、eMMCからデータを読み戻してハッシュ値を照合し、1ビットの狂いもなく書き込めたか（`✅ OK`）をリアルタイムで自動検証します。

#### 💡 リストア時の自動判定優先順位と部分復元（特定のパーティションのみ戻す場合）

`restore_emmc.sh` は、指定したディレクトリ内のファイル構成を自動検出し、以下の優先順位で復元を実行します：

| ディレクトリ内の構成 | 復元の挙動 | 特徴・詳細 |
| :--- | :--- | :--- |
| **`emmc.img`（または `mmcblk0.img`）が存在する場合** | **フルRAWイメージ復元が最優先** | ディレクトリ内に個別パーティション（`mmcblk0p*.img` や `dm250-idb.img`）が同居していても、**`emmc.img` によるディスク丸ごと復元が最優先** され、個別パーティション復元はスキップされます（※ デフォルトの `both` モードでバックアップしたフォルダを指定した場合はこの動作になります）。 |
| **`emmc.img` がなく、個別イメージが存在する場合** | **IDB ＋ 個別パーティション復元** | `dm250-idb.img` が存在する場合は先頭の IDB（セクタ0〜4MB）として復元され、続いて存在する `mmcblk0p*.img` が対応する正確なオフセット位置へ順番に書き戻されます。 |

> [!TIP]
> **🧩 特定のパーティション（辞書やユーザー領域など）のみをピンポイントで復元したい場合**
> バックアップフォルダ（`emmc.img` と分割ファイルが両方入っているフォルダ）をそのまま指定すると、`emmc.img` の全体復元が優先されてしまいます。
> **特定のパーティションのみを書き戻したい場合**は、復元したいファイル（例: `mmcblk0p7.img` や `mmcblk0p8.img`）だけを別の作業フォルダ（例: `./partial_restore/`）にコピーし、そのフォルダを指定して実行してください：
> ```bash
> mkdir -p ./partial_restore
> cp ./factory_backup/mmcblk0p8.img ./partial_restore/  # 辞書パーティションのみ復元したい例
> sudo ./restore_emmc.sh <target_device> ./partial_restore
> ```

> [!TIP]
> **⏱️ リストア時のリアルタイム進捗と検証**
> * **プログレス表示 & ETA 予測**: 書き込み速度およびベリファイ速度から、完了までの残り予測時間をリアルタイム表示。
> * **安全なベリファイ**: 各パーティション書き込み直後に SHA256 ハッシュを自動照合し、整合性を完全に保証。

---

### ステップ 4: 完了と再起動
1. ターミナルに `🎉 Restoration completed successfully!` と表示されたら完了です。
2. USBケーブルを抜きます。
3. SDカードを取り出します。
4. 電源ボタンを長押しして電源を入れ直すと、通常通りシステムが起動します。

---

## ❓ トラブルシューティング & 注意点

| 現象 | 原因と対策 |
| :--- | :--- |
| **`restore_emmc.sh` 実行時に `Read-only file system` や書き込みエラーが出る** | ・挿入されている SD カードがデフォルトの **Read-Only（書き込み禁止）モード** で作成されています。<br>・**対策**: PC で `./prepare_sdcard.sh --readwrite <sd_device>` を実行し、書き込み許可モードの SD カードを作成して再度お試しください。 |
| **macOSで「読み取れないディスク」「初期化/取り出す/無視」が出る** | ・**必ず「無視」を選択してください**。<br>・「初期化」を選ぶと Pomera 内部の全データが消去・破損します。「取り出す」を選ぶと接続が切断されます。Pomera のeMMCはmacOS標準外のLinux/Android形式のため正常な警告です。 |
| **Pomera 画面に `CTRL+C - Operation aborted` と出て勝手に切断される** | ・macOSに接続後、確認プロンプトのまま数十秒放置されたため、macOSのUSB省電力機構（サスペンド）により切断されました。<br>・**対策**: Pomera の電源ボタンを10〜11秒長押しして完全OFF → 再度3〜4秒長押しで起動し、USB接続後は速やかにスクリプトを実行して確認プロンプト（`yes`）を進めてください。 |
| **電源の切り方・SDカードからの起動方法がわからない** | ・**完全電源OFF**: 電源ボタンを **10〜11秒間長押し**。<br>・**SDカードからの起動**: SDカードを挿入後、**電源ボタンのみを3〜4秒間長押し**（他のキーを押す必要はありません）。 |
| **PCにUSB接続しても `/dev/sdX`（`/dev/rdiskN`）が現れない** | ・USBケーブルを挿したまま電源を入れるとUMSが開始されない場合があります。**「USBを抜いた状態で電源ON → 画面点灯後にUSB挿入」** の順序を守ってください。<br>・SDカードが正しく奥まで挿入されているか確認してください。 |
| **USBケーブルを挿し直しても認識されない** | ・Rockchip USBコントローラのハードウェア仕様により、UMS待機中にケーブルを抜いた後の再挿入は自動認識されません。**一度 Pomera の電源ボタンを10〜11秒長押ししてOFFにし、再度3〜4秒長押しして入れ直してください**。 |
| **電源が入らない・画面がつかない** | ・バッテリーが完全に放電している可能性があります。USB充電器にしばらく接続して充電してから再試行してください。<br>・電源ボタンを10〜11秒長押しして強制完全オフにしてから、再度3〜4秒長押しでお試しください。 |
| **バックアップファイルが見つからない** | ・`emmc.img` または `dm250-idb.img` / `mmcblk0p1.img` 〜 `mmcblk0p27.img` を `restore_file/` ディレクトリに配置するか、引数でバックアップ先ディレクトリを指定してください（例: `./restore_emmc.sh <target_device> ./backup_file` ※Linux: `/dev/sdX`, macOS: `/dev/rdiskN`）。 |

---

## 📁 スクリプト構成一覧

* [`prepare_sdcard.sh`](./prepare_sdcard.sh) : SDカード用 U-Boot UMS ブートローダー生成スクリプト（デフォルト: 安全な Read-Only / `--readwrite` で書き込み許可）
* [`backup_emmc.sh`](./backup_emmc.sh) : UMSマウントされたeMMCからPCへ完全バックアップ（フルRAW & IDB + 27パーティション）を取得するスクリプト
* [`restore_emmc.sh`](./restore_emmc.sh) : UMSマウントされたeMMCへの安全なdd書き戻し＆自動検証スクリプト
* [`common.sh`](./common.sh) : クロスプラットフォーム（Linux & macOS）共通ユーティリティライブラリ（アンマウント、ハッシュ計算、パーティションオフセット定義）
* [`patches/uboot_ums_readonly.patch`](./patches/uboot_ums_readonly.patch) : U-Boot Read-Only UMS パッチ（ライトプロテクト保護）
* [`patches/uboot_ums_readwrite.patch`](./patches/uboot_ums_readwrite.patch) : U-Boot Read-Write UMS パッチ（書き込み許可＆接続通知）

---

## 🔗 参考リンク・謝辞

* **Joshua Stein (jcs)**: [Installing OpenBSD on the Pomera DM250](https://jcs.org/2026/04/09/openbsd-dm250) (U-Boot/DDR移植、UMSブートローダー、ハードウェア解析)
* **@ichinomoto 氏**: [EKESETE.net](https://www.ekesete.net/log/?p=9504) (Pomera eMMC バックアップ・リストアスクリプト)

---

## 📜 ライセンス (License)

本プロジェクトは [MIT License](LICENSE) のもとで公開されています。
