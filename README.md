# mi_printer

**English** | [中文](README.zh-TW.md)

A **Dart / Flutter** package for the Xiaomi Mi Portable Photo Printer (MIoT model `hannto.printer.basil`). It lets your app connect to the printer over Bluetooth and print photos directly — no companion app needed. Android is the primary platform; iOS is a secondary target.

What you can do with it:

- Connect to a paired printer over Bluetooth Classic
- Check printer status: battery, idle/printing state, error codes
- Prepare any image (pick from your photo library or elsewhere) to the exact print format
- Print one or more copies, with live transfer / progress / stage updates (pre-heat, paper load, printing…)

## Repository layout

- `lib/` — pure-Dart protocol core (usable directly as a package dependency)
- `example/` — Flutter example app, Android-first, with a native RFCOMM platform channel
- `dist/` — prebuilt Android APK

## Adding the package to your Flutter project (git dependency)

`mi_printer` is a pure-Dart package (its only dependency is `image`) — it contains **no Bluetooth code itself**; see [below](#important-you-must-provide-the-transport) for how Bluetooth is wired up. In **your app's** `pubspec.yaml`:

**Option A — SSH** (`git@github.com:...`)

```yaml
dependencies:
  mi_printer:
    git:
      url: git@github.com:ljcucc/mi_portable_photo_printer.git
```

> ⚠️ Requires a GitHub SSH key set up on your machine (see
> [Connecting to GitHub with SSH](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)).

**Option B — HTTPS** (works out of the box for public repos, e.g. in CI)

```yaml
dependencies:
  mi_printer:
    git:
      url: https://github.com/ljcucc/mi_portable_photo_printer.git
```

> Both forms fetch the same repository — pick one. `flutter pub get` will clone it into your `.pub-cache`.

Then run:

```bash
flutter pub get
```

Import it in Dart:

```dart
import 'package:mi_printer/mi_printer.dart';
```

### Important: you must provide the transport

Bluetooth Classic (RFCOMM/SPP) is platform-specific and Flutter has no built-in API for it (the popular Bluetooth packages are BLE-only; this printer is SPP, not BLE). The package therefore defines a `PrinterTransport` interface — plain bytes in / bytes out — and your app plugs in a native implementation:

- **Android**: copy `example/lib/android_transport.dart` (`AndroidRfcommTransport`, bridging a MethodChannel / EventChannel) and `example/android/.../MainActivity.kt` (native Kotlin `BluetoothAdapter` → `BluetoothSocket` (SPP UUID `00001101-…`, channel 1), with read/write threads) into your project, then adjust package names.
- **Other platforms**: implement the `PrinterTransport` interface (`open()` / `close()` / `rxStream` / `write()` / `isOpen`) against that platform's native Bluetooth API.
- **Unit tests**: the package ships with `FakeTransport` (in-memory).

## Quick start

```dart
import 'package:mi_printer/mi_printer.dart';
// On Android you also need your transport implementation, e.g.:
// import 'android_transport.dart';

final transport = AndroidRfcommTransport('AA:BB:CC:DD:EE:FF'); // printer MAC
final cipher = Rc4Cipher.fromToken('your-24-hex-char-miio-token');
final printer = Printer(transport, cipher);

await printer.connect(); // subscribes to rx before opening the socket
try {
  // 1. Read status (battery / idle-or-printing / error code)
  final st = await printer.status();
  print(st); // PrinterStatus(idle/idle, err=0, battery=100)

  // 2. Prepare the print image: any decodable image bytes → 1040x1560 baseline JPEG
  //    fit: 'cover' (fill + center-crop, default) | 'contain' (letterbox) | 'stretch'
  final jpeg = preparePrintImage(sourceBytes, fit: 'cover');

  // 3. Print and wait for completion
  final result = await printer.printImage(
    jpeg,
    copies: 1,
    onTransferProgress: (sent, total) => print('transfer $sent/$total'),
    onStatus: (s) => print('status: $s'), // pre-heat / paper load / printing ...
  );
  print('job ${result.jobId} finished: ${result.jobInfo}');
} finally {
  await printer.close();
}
```

API overview:

| Method | Description |
|---|---|
| `printer.connect()` / `close()` | Open / close the Bluetooth link |
| `printer.status()` | Battery, state (idle / printing), error code, auto-off time left |
| `printer.deviceInfo()` | Firmware version, serial, MAC, device id |
| `printer.retime()` | Reset the ~10-minute auto-off timer (**the only** method that does; polling status does not) |
| `printer.startJob(...)` / `sendFile(...)` / `confirmJob(...)` | Drive the print job step by step |
| `printer.printImage(jpeg, ...)` | Run a whole print job in one call |
| `printer.rpc(method, params)` | Send a raw protocol request (low-level API) |
| `printer.events()` | Pop printer events (e.g. the lifetime print counter) |
| `preparePrintImage(bytes, fit: ...)` | Fit any image to the print format: cover / contain / stretch |

Caveats:

- A dropped link mid-job cannot resume — the job is dead and must be reprinted.
- The printer drops an idle link after ~15 s and powers off after ~10 minutes — both are normal.
- The `miio token` is a device secret; never commit it to source control or share it publicly.

## Prerequisites

- The printer only supports Bluetooth Classic (SPP / RFCOMM), **not BLE**; pair it once in the OS Bluetooth settings first.
- You need the device's 24-hex miio token; get it with [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) (model `hannto.printer.basil`).
- Android 12+ requires the "Nearby devices" permission.

See [`example/README.md`](example/README.md) for detailed example-app instructions.

## Developing / building this repo (FVM recommended)

Use [FVM (Flutter Version Management)](https://fvm.app/) to pin the Flutter version. This project is built with **Flutter 3.44.0**.

```bash
# Install FVM (if not installed)
dart pub global activate fvm

# Install and select the version in the repo root
fvm install 3.44.0
fvm use 3.44.0

# Fetch dependencies
fvm flutter pub get
cd example && fvm flutter pub get && cd ..

# Build the Android release APK
cd example
fvm flutter build apk --release
```

Run all commands from the repo root; `fvm flutter` automatically uses the version chosen with `fvm use`. To make cloned checkouts pick the version automatically, add a `.fvmrc` file at the root containing `3.44.0`; afterwards `fvm use` is enough.

Build output lands in `example/build/app/outputs/flutter-apk/app-release.apk`; ready-made APKs are in `dist/`.

### Building with Docker (when Flutter / FVM is not installed)

If Flutter / Dart / FVM are not installed locally, build via Docker:

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v flutter_pub_cache:/root/.pub-cache \
  -v flutter_gradle_cache:/root/.gradle \
  --memory=2500m --memory-swap=3500m \
  ghcr.io/cirruslabs/flutter:latest \
  bash -c "cd /work/example && nice -n 15 flutter build apk --release"
```

## Acknowledgements

The Bluetooth protocol is based on knowledge reverse-engineered by **[fliptheweb/mi-portable-photo-printer](https://github.com/fliptheweb/mi-portable-photo-printer)**. The protocol is not officially authorized by Xiaomi / Hannto; use at your own risk.

## License

This package is provided as-is, with no warranty.
