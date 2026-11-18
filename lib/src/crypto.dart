/// Payload encryption for the Mi Portable Photo Printer (Hannto `mijia`
/// scheme, encType 4).
///
/// Every frame body is RC4-encrypted with a *fresh* key schedule (KSA) each
/// time, keyed with the printer's 12-byte Xiaomi device token. The keystream
/// is therefore identical at the same offset in every frame, so a precomputed
/// keystream (>= 928 bytes) is an equivalent secret to the token itself.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The first [n] bytes of the RC4 keystream for [key].
Uint8List rc4Keystream(List<int> key, int n) {
  final s = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 0xFF;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
  }
  final out = Uint8List(n);
  var i = 0;
  j = 0;
  for (var k = 0; k < n; k++) {
    i = (i + 1) & 0xFF;
    j = (j + s[i]) & 0xFF;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
    out[k] = s[(s[i] + s[j]) & 0xFF];
  }
  return out;
}

class Rc4Cipher {
  Rc4Cipher._(this._ks);

  /// Build from the printer's miio token (24 hex chars / 12 bytes).
  factory Rc4Cipher.fromToken(String hexToken, {int span = 1024}) =>
      Rc4Cipher._(rc4Keystream(_decodeHex(hexToken), span));

  factory Rc4Cipher.fromTokenBytes(List<int> token, {int span = 1024}) =>
      Rc4Cipher._(rc4Keystream(token, span));

  /// Build from a raw keystream recovered from a capture.
  factory Rc4Cipher.fromKeystream(Uint8List keystream) {
    if (keystream.length < minSpan) {
      throw ArgumentError(
          'keystream must cover at least $minSpan bytes (one full file chunk)');
    }
    return Rc4Cipher._(keystream);
  }

  /// One full file chunk (4-byte job id + up to 924 JPEG bytes).
  static const int minSpan = 928;

  final Uint8List _ks;

  /// RC4 is symmetric: this both encrypts and decrypts. Because the KSA is
  /// re-run for every frame, always start from keystream offset 0.
  Uint8List crypt(Uint8List data) {
    final r = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      r[i] = data[i] ^ _ks[i];
    }
    return r;
  }

  static Uint8List _decodeHex(String hexToken) {
    final h =
        hexToken.trim().toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');
    if (h.length != 24) {
      throw ArgumentError(
          'token must be 24 hex chars (12 bytes), got ${h.length}');
    }
    return Uint8List.fromList(List.generate(
        12, (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)));
  }
}

/// Helper used by tooling/tests: hex-encode bytes.
String hexEncode(List<int> bytes) => bytes.map((b) {
      final v = b & 0xFF;
      return '${v < 16 ? '0' : ''}${v.toRadixString(16)}';
    }).join();

/// Helper used by tooling/tests: hex-decode a string.
Uint8List hexDecode(String hex) {
  final h = hex.trim().toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Convenience for decoding a keystream stored as base64.
Uint8List keystreamFromBase64(String b64) =>
    Uint8List.fromList(base64Decode(b64));
