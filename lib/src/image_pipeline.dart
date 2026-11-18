/// Prepare an image for the printer: exactly 1040 x 1560 px, baseline JPEG.
///
/// Port of `mizink/image.py` using the pure-Dart `image` package.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const int printW = 1040;
const int printH = 1560;

/// Return baseline JPEG bytes sized 1040x1560.
///
/// [fit]:
///  * 'cover'   — scale to fill, then centre-crop (no borders, may lose edges)
///  * 'contain' — scale to fit, pad with [background] (whole image kept)
///  * 'stretch' — ignore aspect ratio
Uint8List preparePrintImage(
  Uint8List source, {
  String fit = 'cover',
  int quality = 90,
}) {
  var im = img.decodeImage(source);
  if (im == null) throw ArgumentError('not a decodable image');
  im = img.bakeOrientation(im); // apply EXIF orientation

  final img.Image out;
  switch (fit) {
    case 'cover':
      out = _resizeCover(im, printW, printH);
      break;
    case 'contain':
      out = _resizeContain(im, printW, printH, img.ColorRgb8(255, 255, 255));
      break;
    case 'stretch':
      out = img.copyResize(im,
          width: printW, height: printH, interpolation: img.Interpolation.cubic);
      break;
    default:
      throw ArgumentError('unknown fit mode "$fit"');
  }

  // Baseline (non-progressive) JPEG with standard Huffman tables.
  final encoded = img.encodeJpg(out, quality: quality);
  return Uint8List.fromList(encoded);
}

img.Image _resizeCover(img.Image src, int w, int h) {
  final scale = math.max(w / src.width, h / src.height);
  final resized = img.copyResize(src,
      width: (src.width * scale).round().clamp(w, 1 << 30),
      height: (src.height * scale).round().clamp(h, 1 << 30),
      interpolation: img.Interpolation.cubic);
  final x = ((resized.width - w) ~/ 2).clamp(0, resized.width - w);
  final y = ((resized.height - h) ~/ 2).clamp(0, resized.height - h);
  return img.copyCrop(resized, x: x, y: y, width: w, height: h);
}

img.Image _resizeContain(
    img.Image src, int w, int h, img.ColorRgb8 background) {
  final out = img.Image(width: w, height: h, numChannels: 3);
  img.fill(out, color: background);
  final scale = math.min(w / src.width, h / src.height);
  final scaled = img.copyResize(src,
      width: (src.width * scale).round().clamp(1, w),
      height: (src.height * scale).round().clamp(1, h),
      interpolation: img.Interpolation.cubic);
  img.compositeImage(out, scaled,
      dstX: (w - scaled.width) ~/ 2, dstY: (h - scaled.height) ~/ 2);
  return out;
}
