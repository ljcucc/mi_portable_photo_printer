import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:mi_printer/src/transport.dart';

/// RFCOMM transport for Android, backed by a platform channel implemented in
/// MainActivity.kt.
///
/// Channels:
///  * MethodChannel "mi_printer/transport": open/write/close/isOpen
///  * EventChannel  "mi_printer/transport/rx": raw rx bytes
class AndroidRfcommTransport implements PrinterTransport {
  AndroidRfcommTransport(this.address);

  final String address;

  static const _method = MethodChannel('mi_printer/transport');
  static const _rx = EventChannel('mi_printer/transport/rx');

  StreamController<Uint8List>? _controller;
  StreamSubscription<dynamic>? _sub;
  bool _open = false;

  @override
  Stream<Uint8List> get rxStream {
    _controller ??= StreamController<Uint8List>.broadcast();
    return _controller!.stream;
  }

  @override
  bool get isOpen => _open;

  @override
  Future<void> open() async {
    // Listen first so nothing is lost, then connect.
    _sub ??= _rx.receiveBroadcastStream().listen((data) {
      if (data is Uint8List) {
        _controller?.add(data);
      } else if (data is List) {
        _controller?.add(Uint8List.fromList(List<int>.from(data)));
      }
    }, onError: (Object e) {
      _open = false;
      _controller?.addError(PrinterTransportError('rx stream error', e));
    });

    try {
      await _method.invokeMethod<void>('open', {'address': address});
      _open = true;
    } on PlatformException catch (e) {
      _open = false;
      throw PrinterTransportError(
          'connect failed: ${e.code} ${e.message ?? ''}', e);
    }
  }

  @override
  Future<void> close() async {
    try {
      await _method.invokeMethod<void>('close');
    } on PlatformException {
      // ignore
    }
    _open = false;
    await _sub?.cancel();
    _sub = null;
  }

  @override
  Future<void> write(Uint8List data) async {
    if (!_open) throw PrinterTransportError('transport is closed');
    await _method.invokeMethod<void>('write', data);
  }
}
