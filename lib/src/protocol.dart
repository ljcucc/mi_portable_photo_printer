/// Hannto wire protocol: the 0x7E-delimited frame.
///
/// Frame layout (22 + bodyLen bytes), little-endian fields:
///
///     off  size  field
///     0    1     0x7E head
///     1    1     0x64 version
///     2    1     0x00 reserved
///     3    1     channel   (1=JSON, 2=file, 255=auth)
///     4    1     interactive (6=request, 7=response)
///     5    1     encoding  (2=binary/hex, 3=json)
///     6    4     arcMsgSn u32 LE (always 0)
///     10   4     msgSn u32 LE (per-side counter)
///     14   2     packageTotal u16 LE
///     16   2     packageNum u16 LE (1-based)
///     18   2     msgAttribute = bodyLen | encType<<10 | 0x2000 if multi-package
///     20   N     body
///     20+N 1     checksum = (sum(all bytes, checksum & tail = 0) - 126) & 0xFF
///     21+N 1     0x7E tail
library;

import 'dart:typed_data';

const int frameHead = 0x7E;
const int frameTail = 0x7E;
const int frameVersion = 0x64;

const int chJson = 1;
const int chFile = 2;
const int chAuth = 255;

const int frameRequest = 6;
const int frameResponse = 7;

const int encBinary = 1;
const int encHex = 2;
const int encJson = 3;

const int encTypeNone = 0;
const int encTypeMijia = 4; // RC4 with the device token

/// Compute the frame checksum over `buf[start .. start+20+n]`
/// (the region *without* checksum and tail bytes).
int frameChecksum(Uint8List buf, int start, int n) {
  var sum = 0;
  for (var i = start; i < start + 20 + n; i++) {
    sum += buf[i];
  }
  return (sum - 126) & 0xFF;
}

/// Assemble one wire frame. [body] must already be encrypted when [encType]
/// says so.
Uint8List buildFrame({
  required int channel,
  required int interactive,
  required int encoding,
  required int msgSn,
  required Uint8List body,
  int encType = encTypeNone,
  int pkgTotal = 1,
  int pkgNum = 1,
  int arcSn = 0,
}) {
  final n = body.length;
  final f = Uint8List(22 + n);
  final bd = ByteData.sublistView(f);
  f[0] = frameHead;
  f[1] = frameVersion;
  f[2] = 0;
  f[3] = channel;
  f[4] = interactive;
  f[5] = encoding;
  bd.setUint32(6, arcSn, Endian.little);
  bd.setUint32(10, msgSn, Endian.little);
  bd.setUint16(14, pkgTotal, Endian.little);
  bd.setUint16(16, pkgNum, Endian.little);
  final attr = n | (encType << 10) | (pkgTotal > 1 ? 0x2000 : 0);
  bd.setUint16(18, attr, Endian.little);
  f.setRange(20, 20 + n, body);
  f[20 + n] = frameChecksum(f, 0, n);
  f[21 + n] = frameTail;
  return f;
}

class Frame {
  Frame({
    required this.channel,
    required this.interactive,
    required this.encoding,
    required this.msgSn,
    required this.pkgTotal,
    required this.pkgNum,
    required this.encType,
    required this.body,
    required this.checksumOk,
  });

  final int channel;
  final int interactive;
  final int encoding;
  final int msgSn;
  final int pkgTotal;
  final int pkgNum;
  final int encType;
  final Uint8List body;
  final bool checksumOk;

  @override
  String toString() =>
      'Frame(ch: $channel, act: $interactive, enc: $encoding, sn: $msgSn, '
      'pkg: $pkgNum/$pkgTotal, encType: $encType, len: ${body.length}, '
      'cksum: $checksumOk)';
}

/// Streaming frame reassembler. Feed arbitrary rx chunks to [add]; complete
/// frames are returned and the leftover bytes are kept internally until more
/// data arrives.
class FrameParser {
  Uint8List _buf = Uint8List(0);

  List<Frame> add(List<int> chunk) {
    final b = BytesBuilder(copy: false);
    b.add(_buf);
    b.add(chunk);
    _buf = b.toBytes();

    final out = <Frame>[];
    final bd = ByteData.sublistView(_buf);
    var i = 0;
    while (i + 22 <= _buf.length) {
      if (_buf[i] != frameHead) {
        i++;
        continue;
      }
      final attr = bd.getUint16(i + 18, Endian.little);
      final n = attr & 0x3FF;
      if (i + 22 + n > _buf.length) break; // incomplete -> wait for more
      if (_buf[i + 21 + n] != frameTail) {
        i++;
        continue; // bad frame -> resync
      }
      out.add(Frame(
        channel: _buf[i + 3],
        interactive: _buf[i + 4],
        encoding: _buf[i + 5],
        msgSn: bd.getUint32(i + 10, Endian.little),
        pkgTotal: bd.getUint16(i + 14, Endian.little),
        pkgNum: bd.getUint16(i + 16, Endian.little),
        encType: (attr >> 10) & 0x7,
        body: Uint8List.fromList(_buf.sublist(i + 20, i + 20 + n)),
        checksumOk: _buf[i + 20 + n] == frameChecksum(_buf, i, n),
      ));
      i += 22 + n;
    }
    if (i > 0) _buf = Uint8List.fromList(_buf.sublist(i));
    return out;
  }
}
