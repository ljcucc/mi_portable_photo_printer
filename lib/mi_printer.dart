/// mi_printer — Dart port of the `mizink` protocol for the
/// Xiaomi Mi Portable Photo Printer (hannto.printer.basil).
///
/// Layers:
///  * [FrameParser] / [buildFrame] — the 0x7E wire frame (protocol.dart)
///  * [Rc4Cipher]                  — mijia RC4 with per-frame KSA (crypto.dart)
///  * [PrinterTransport]           — RFCOMM abstraction (transport.dart)
///  * [Printer]                    — JSON-RPC + print workflow (printer.dart)
///  * [preparePrintImage]          — 1040x1560 baseline JPEG pipeline (image_pipeline.dart)
library mi_printer;

export 'src/crypto.dart';
export 'src/image_pipeline.dart';
export 'src/printer.dart';
export 'src/protocol.dart';
export 'src/transport.dart';
