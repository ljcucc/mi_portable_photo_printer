# mi_printer

[English](README.md) | **中文**

以 **Dart / Flutter** 操作小米口袋相片印表機（Mi Portable Photo Printer，MIoT model `hannto.printer.basil`）的套件。讓你的 app 透過藍牙直接連上印表機並列印照片——不必另開官方 app。Android 為主要平台，iOS 為次要目標。

這個套件能做什麼：

- 透過藍牙 Classic 連上已配對的印表機
- 查詢印表機狀態：電量、閒置/列印中、錯誤碼
- 把任何來源的圖片（相簿選圖或其他）處理成印表機要求的列印格式
- 列印一張或多張，並即時取得傳輸與列印進度（預熱、進紙、列印中…）

## 專案結構

- `lib/` — 純 Dart 協定核心（可直接做為套件依賴）
- `example/` — Flutter 範例 app，Android 為主，含原生 RFCOMM platform channel
- `dist/` — 已建置的 Android APK

## 把套件加到你的 Flutter 專案（git 依賴）

`mi_printer` 是純 Dart 套件（唯一的依賴是 `image`）——**套件本身不含藍牙程式碼**，藍牙怎麼接見[下方說明](#重要transport-需自行實作)。不需要以 path 引用，直接用 git 依賴即可。在 **你的 app** 的 `pubspec.yaml` 加入：

**方式 A — SSH**（`git@github.com:...`）

```yaml
dependencies:
  mi_printer:
    git:
      url: git@github.com:ljcucc/mi_portable_photo_printer.git
```

> ⚠️ 需要先在你的機器上設定 GitHub SSH key（參考
> [Connecting to GitHub with SSH](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)）。

**方式 B — HTTPS**（公開 repo 開箱即用，適合 CI 環境）

```yaml
dependencies:
  mi_printer:
    git:
      url: https://github.com/ljcucc/mi_portable_photo_printer.git
```

> 兩種形式抓的是同一個 repo，擇一即可。`flutter pub get` 時會 clone 到 `.pub-cache`。

然後執行：

```bash
flutter pub get
```

在 Dart 中 import：

```dart
import 'package:mi_printer/mi_printer.dart';
```

### 重要：transport 需自行實作

Bluetooth Classic（RFCOMM/SPP）屬於平台原生功能，Flutter 沒有內建 API（常見的藍牙套件都只支援 BLE，而這台印表機是 SPP 不是 BLE）。因此套件只定義 `PrinterTransport` 介面——單純的 bytes 進 / bytes 出——由你的 app 接上平台原生的實作：

- **Android**：複製 `example/lib/android_transport.dart`（`AndroidRfcommTransport`，透過 MethodChannel / EventChannel 橋接）與 `example/android/.../MainActivity.kt`（原生 Kotlin：`BluetoothAdapter` → `BluetoothSocket`，SPP UUID `00001101-…`、channel 1，含讀寫 thread）到你的專案，並調整 package 名稱。
- **其他平台**：對該平台的原生藍牙 API 實作 `PrinterTransport` 介面（`open()` / `close()` / `rxStream` / `write()` / `isOpen`）。
- **單元測試**：套件內建 `FakeTransport`（in-memory）。

## 快速上手

```dart
import 'package:mi_printer/mi_printer.dart';
// Android 另需你的 transport 實作，例如：
// import 'android_transport.dart';

final transport = AndroidRfcommTransport('AA:BB:CC:DD:EE:FF'); // 印表機 MAC
final cipher = Rc4Cipher.fromToken('你的24個hex字元miio token');
final printer = Printer(transport, cipher);

await printer.connect(); // 先訂閱 rx 再開 socket，避免漏掉早期的回覆
try {
  // 1. 讀狀態（電量 / 閒置或列印中 / 錯誤碼）
  final st = await printer.status();
  print(st); // PrinterStatus(idle/idle, err=0, battery=100)

  // 2. 準備列印圖：任何可解碼的圖檔 bytes → 1040x1560 baseline JPEG
  //    fit: 'cover'（填滿置中裁切，預設）| 'contain'（留白）| 'stretch'（變形）
  final jpeg = preparePrintImage(sourceBytes, fit: 'cover');

  // 3. 列印並等待完成
  final result = await printer.printImage(
    jpeg,
    copies: 1,
    onTransferProgress: (sent, total) => print('傳輸 $sent/$total'),
    onStatus: (s) => print('狀態: $s'), // 預熱 / 進紙 / 列印中 ...
  );
  print('job ${result.jobId} 完成: ${result.jobInfo}');
} finally {
  await printer.close();
}
```

常用 API 一覽：

| 方法 | 說明 |
|---|---|
| `printer.connect()` / `close()` | 開 / 關藍牙連線 |
| `printer.status()` | 電量、狀態（閒置 / 列印中）、錯誤碼、自動關機剩餘時間 |
| `printer.deviceInfo()` | 韌體版本、序號、MAC、裝置 id |
| `printer.retime()` | 重置 ~10 分鐘自動關機計時（**唯一**會重置的方法，讀狀態不算） |
| `printer.startJob(...)` / `sendFile(...)` / `confirmJob(...)` | 分步控制列印流程 |
| `printer.printImage(jpeg, ...)` | 一鍵完成整個列印 job |
| `printer.rpc(method, params)` | 直接送協定請求（底層 API） |
| `printer.events()` | 取出印表機主動回報的事件（如終身列印張數） |
| `preparePrintImage(bytes, fit: ...)` | 把任何圖片調整成列印格式：cover / contain / stretch |

注意事項：

- 列印途中斷線無法續傳，job 作廢需重印。
- 印表機閒置 15 秒會斷線、10 分鐘會自動關機 — 都屬正常行為。
- `miio token` 是裝置機密，請勿寫入原始碼或公開分享。

## 使用前準備

- 印表機僅支援藍牙 Classic（SPP / RFCOMM），**不是 BLE**；請先在系統藍牙設定中配對一次。
- 需要裝置的 24-hex miio token，可用 [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) 取得（model `hannto.printer.basil`）。
- Android 12+ 需授予「附近裝置」權限。

範例 app 的詳細操作步驟見 [`example/README.md`](example/README.md)。

## 本 repo 開發 / 建置（建議用 FVM）

建議使用 [FVM（Flutter Version Management）](https://fvm.app/) 固定 Flutter 版本，避免不同專案之間版本衝突。本專案以 **Flutter 3.44.0** 建置。

```bash
# 安裝 FVM（若尚未安裝）
dart pub global activate fvm

# 在專案根目錄安裝並選用版本
fvm install 3.44.0
fvm use 3.44.0

# 取得相依套件
fvm flutter pub get
cd example && fvm flutter pub get && cd ..

# 建 Android Release APK
cd example
fvm flutter build apk --release
```

所有指令都在專案根目錄執行；`fvm flutter` 會自動使用 `fvm use` 指定的版本。若希望 clone 後自動帶入版本，可在根目錄加入 `.fvmrc`（內容為 `3.44.0`），之後只需執行 `fvm use`。

建置產物位於 `example/build/app/outputs/flutter-apk/app-release.apk`；現成的 APK 放在 `dist/`。

### 以 Docker 建置（未安裝 Flutter / FVM 時）

本機若未安裝 Flutter / Dart / FVM，可改用 Docker：

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v flutter_pub_cache:/root/.pub-cache \
  -v flutter_gradle_cache:/root/.gradle \
  --memory=2500m --memory-swap=3500m \
  ghcr.io/cirruslabs/flutter:latest \
  bash -c "cd /work/example && nice -n 15 flutter build apk --release"
```

## 致謝

藍牙協定知識來自 **[fliptheweb/mi-portable-photo-printer](https://github.com/fliptheweb/mi-portable-photo-printer)** 的逆向工程。協定未經 Xiaomi / Hannto 官方授權，使用風險自負。

## 授權

本套件依現狀提供，不附任何擔保。
