/// Transport abstraction for the Hannto protocol.
///
/// The wire transport is Bluetooth Classic RFCOMM channel 1 (SPP). This
/// interface isolates the platform plumbing (Android BluetoothSocket via a
/// platform channel, macOS IOBluetooth, a test double, ...) from the
/// frame/cipher/rpc layers, which are pure Dart.
library;

import 'dart:async';
import 'dart:typed_data';

/// SPP UUID used to open the RFCOMM channel (channel id 1).
const String sppUuid = '00001101-0000-1000-8000-00805F9B34FB';

/// Default RFCOMM channel advertised by the printer.
const int rfcommChannel = 1;

abstract class PrinterTransport {
  /// Open the link. May throw a [PrinterTransportError] on failure.
  Future<void> open();

  /// Close the link.
  Future<void> close();

  /// Raw received bytes. Chunks have arbitrary boundaries — never assume a
  /// chunk aligns with a frame.
  Stream<Uint8List> get rxStream;

  /// Write raw bytes (usually one whole frame).
  Future<void> write(Uint8List data);

  bool get isOpen;
}

class PrinterTransportError implements Exception {
  PrinterTransportError(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'PrinterTransportError: $message${cause != null ? ' ($cause)' : ''}';
}

/// In-memory transport for unit tests: [writes] records every write and
/// [push] injects synthetic rx data.
class FakeTransport implements PrinterTransport {
  final writes = <Uint8List>[];
  final _controller = StreamController<Uint8List>.broadcast();

  @override
  bool get isOpen => _open;
  bool _open = false;

  @override
  Future<void> open() async => _open = true;

  @override
  Future<void> close() async => _open = false;

  @override
  Stream<Uint8List> get rxStream => _controller.stream;

  @override
  Future<void> write(Uint8List data) async {
    if (!_open) throw PrinterTransportError('transport is closed');
    writes.add(Uint8List.fromList(data));
  }

  void push(Uint8List data) => _controller.add(data);
}
