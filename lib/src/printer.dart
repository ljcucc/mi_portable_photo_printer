library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'protocol.dart';
import 'transport.dart';

/// JPEG bytes per file frame (4-byte job id is prepended => 928-byte body).
const int fileChunkSize = 924;

/// print_job error code when the printer is busy / not yet ready.
const int errBusy = -8006;

class PrinterException implements Exception {
  PrinterException(this.message);
  final String message;

  @override
  String toString() => 'PrinterException: $message';
}

/// Reply of `mixed_status`.
class PrinterStatus {
  PrinterStatus({
    required this.category,
    required this.subCategory,
    required this.error,
    this.battery,
    this.timeLeftMs,
    this.raw = const {},
  });

  factory PrinterStatus.fromMap(Map<String, dynamic> m) => PrinterStatus(
        category: (m['category'] as String?) ?? 'unknown',
        subCategory: (m['sub_category'] as String?) ?? 'unknown',
        error: (m['error'] as num?)?.toInt() ?? 0,
        battery: (m['battery'] as num?)?.toInt(),
        timeLeftMs: (m['time_left'] as num?)?.toInt(),
        raw: m,
      );

  final String category; // idle | processing
  final String subCategory; // init|smart_sheet|decoding|pre_heat|load_paper|printing|idle
  final int error;
  final int? battery;
  final int? timeLeftMs; // ms left until auto-off (read-only observation)
  final Map<String, dynamic> raw;

  @override
  String toString() =>
      'PrinterStatus($category/$subCategory, err=$error, battery=$battery)';
}

/// Reply of `job_info` (result[0]).
class JobInfo {
  JobInfo({
    required this.jobId,
    required this.jobType,
    required this.jobState,
    this.prtCopies,
    this.transferTimeMs,
    this.printTimeMs,
    this.raw = const {},
  });

  factory JobInfo.fromMap(Map<String, dynamic> m) => JobInfo(
        jobId: (m['job_id'] as num?)?.toInt() ?? 0,
        jobType: (m['job_type'] as num?)?.toInt() ?? 0,
        jobState: (m['job_state'] as String?) ?? '',
        prtCopies: (m['prt_copies'] as num?)?.toInt(),
        transferTimeMs: (m['transfer_time'] as num?)?.toInt(),
        printTimeMs: (m['print_time'] as num?)?.toInt(),
        raw: m,
      );

  final int jobId;
  final int jobType;
  final String jobState;
  final int? prtCopies;
  final int? transferTimeMs;
  final int? printTimeMs;
  final Map<String, dynamic> raw;

  bool get isFinished => jobState == 'finished';

  @override
  String toString() =>
      'JobInfo(job: $jobId, state: $jobState, copies: $prtCopies, '
      'printTime: $printTimeMs ms)';
}

/// Counters from the unsolicited `event.big_data` event.
class Telemetry {
  Telemetry({this.printedTotal, this.finishedTotal, this.tmdCode, this.did});

  factory Telemetry.fromParams(Map<String, dynamic> params) {
    final total = (params['total'] as Map?)?.cast<String, dynamic>() ?? {};
    return Telemetry(
      printedTotal: (total['printed'] as num?)?.toInt(),
      finishedTotal: (total['finished'] as num?)?.toInt(),
      tmdCode: params['TMD_code'] as String?,
      did: params['did'],
    );
  }

  final int? printedTotal; // printer's lifetime print counter
  final int? finishedTotal;
  final String? tmdCode;
  final dynamic did;

  @override
  String toString() =>
      'Telemetry(printed_total: $printedTotal, finished_total: $finishedTotal)';
}

class Printer {
  Printer(this.transport, this.cipher);

  final PrinterTransport transport;
  final Rc4Cipher cipher;

  int _sn = 0;
  final FrameParser _parser = FrameParser();
  final List<Uint8List> _pendingBodies = [];
  StreamSubscription<Uint8List>? _sub;
  bool _listening = false;

  Telemetry? lastTelemetry;

  /// Subscribe before [open] so no early rx bytes are lost.
  Future<void> connect() async {
    _startListening();
    await transport.open();
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await transport.close();
  }

  bool get isConnected => transport.isOpen;

  void _startListening() {
    if (_listening) return;
    _listening = true;
    _sub = transport.rxStream.listen((chunk) {
      for (final f in _parser.add(chunk)) {
        var body = f.body;
        if (f.encType != encTypeNone) body = cipher.crypt(body);
        if (f.channel == chJson) {
          if (_pendingBodies.length > 64) _pendingBodies.removeAt(0);
          _pendingBodies.add(body);
        }
        // chFile frames from the printer are not expected; ignore.
      }
    });
  }

  Map<String, dynamic>? _tryJson(Uint8List body) {
    try {
      final j = json.decode(utf8.decode(body));
      return j is Map<String, dynamic> ? j : null;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// Send one JSON-RPC request and wait for the matching reply.
  ///
  /// [expectReply] must be false for methods that never reply (e.g.
  /// `clean_data`).
  Future<Map<String, dynamic>> rpc(
    String method,
    Object? params, {
    Duration timeout = const Duration(seconds: 15),
    bool expectReply = true,
  }) async {
    final mid = ++_sn;
    final payload = utf8.encode(json.encode({
      'id': mid,
      'method': method,
      'params': params,
    }));
    final frame = buildFrame(
      channel: chJson,
      interactive: frameRequest,
      encoding: encJson,
      msgSn: mid,
      body: cipher.crypt(payload),
      encType: encTypeMijia,
    );
    await transport.write(frame);

    if (!expectReply) {
      // Give concurrently arriving frames time to land, then return.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return {};
    }

    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      for (var i = 0; i < _pendingBodies.length; i++) {
        final j = _tryJson(_pendingBodies[i]);
        if (j != null && j['id'] == mid) {
          _pendingBodies.removeAt(i);
          return j;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    throw PrinterException('timeout waiting for reply to "$method"');
  }

  /// Pop all unsolicited JSON events (no `id` key), e.g. `event.big_data`.
  List<Map<String, dynamic>> events() {
    final out = <Map<String, dynamic>>[];
    _pendingBodies.removeWhere((body) {
      final j = _tryJson(body);
      if (j != null && j['id'] == null) {
        out.add(j);
        return true;
      }
      return false;
    });
    return out;
  }

  // -- commands ---------------------------------------------------------

  /// `mixed_status` — battery, state, error, time_left.
  Future<PrinterStatus> status() async {
    final r = await rpc('mixed_status', []);
    final res = r['result'];
    return PrinterStatus.fromMap(
        res is Map<String, dynamic> ? res : <String, dynamic>{});
  }

  /// `get_prop` — firmware / serial / mac / did.
  Future<Map<String, dynamic>> deviceInfo() async {
    final r = await rpc('get_prop', ['device_info']);
    final res = r['result'];
    if (res is List && res.isNotEmpty && res.first is Map) {
      return (res.first as Map).cast<String, dynamic>();
    }
    return {};
  }

  /// `clean_data` — reset the data channel before every job. Fire-and-forget:
  /// the printer never replies.
  Future<void> cleanData() async {
    await rpc('clean_data', {'delay_times': 0}, expectReply: false);
  }

  /// `retime` — reset the ~10-minute idle auto-off timer. This is the only
  /// method that does it; reading status does not.
  Future<void> retime() => rpc('retime', []);

  /// `job_info` — per-job progress / result.
  Future<JobInfo> jobInfo(int jobId) async {
    final r = await rpc('job_info', [jobId]);
    final res = r['result'];
    if (res is List && res.isNotEmpty && res.first is Map) {
      return JobInfo.fromMap((res.first as Map).cast<String, dynamic>());
    }
    throw PrinterException('job_info returned no data: $r');
  }

  /// `print_job` — open a print job, retrying on busy (-8006).
  Future<int> startJob({
    required int fileSize,
    int copies = 1,
    Duration busyTimeout = const Duration(seconds: 30),
  }) async {
    final end = DateTime.now().add(busyTimeout);
    var delay = const Duration(milliseconds: 500);
    while (true) {
      final r = await rpc('print_job', {
        'copies': copies,
        'channel': 64,
        'job_type': 0,
        'file_size': fileSize,
      }, timeout: const Duration(seconds: 30));
      final res = r['result'];
      if (res is Map && res['job_id'] != null) {
        return (res['job_id'] as num).toInt();
      }
      final err = r['error'];
      final code = err is Map ? (err['code'] as num?)?.toInt() : null;
      if (code == errBusy) {
        if (DateTime.now().isAfter(end)) {
          throw PrinterException(
              'printer stayed busy for >30s (error $errBusy)');
        }
        await Future<void>.delayed(delay);
        final next = delay * 1.5;
        delay = next > const Duration(seconds: 3)
            ? const Duration(seconds: 3)
            : next;
        continue;
      }
      throw PrinterException('print_job rejected: $r');
    }
  }

  /// Stream [jpeg] to the printer on the file channel (channel 2).
  Future<void> sendFile(
    int jobId,
    Uint8List jpeg, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final total = (jpeg.length + fileChunkSize - 1) ~/ fileChunkSize;
    final jid = Uint8List(4);
    ByteData.sublistView(jid).setUint32(0, jobId, Endian.little);
    for (var i = 0; i < total; i++) {
      final start = i * fileChunkSize;
      final end = (start + fileChunkSize).clamp(0, jpeg.length);
      final body = Uint8List(4 + (end - start));
      body.setAll(0, jid);
      body.setAll(4, jpeg.sublist(start, end));
      final frame = buildFrame(
        channel: chFile,
        interactive: frameRequest,
        encoding: encHex,
        msgSn: ++_sn,
        body: cipher.crypt(body),
        encType: encTypeMijia,
        pkgTotal: total,
        pkgNum: i + 1,
      );
      await transport.write(frame);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      onProgress?.call(i + 1, total);
    }
  }

  /// `confirm_job` — confirm the transfer, start printing.
  Future<void> confirmJob(int jobId) async {
    final r = await rpc('confirm_job', [jobId]);
    final res = r['result'];
    if (!(res is List) || res.length != 1 || res[0] != 'OK') {
      throw PrinterException('confirm_job failed: $r');
    }
  }

  /// Print a prepared 1040x1560 baseline JPEG.
  ///
  /// See [preparePrintImage] for producing [jpeg] from any source image.
  Future<PrintResult> printImage(
    Uint8List jpeg, {
    int copies = 1,
    bool wait = true,
    Duration timeout = const Duration(seconds: 180),
    void Function(int sent, int total)? onTransferProgress,
    void Function(PrinterStatus status)? onStatus,
  }) async {
    await cleanData(); // the native app resets the data channel before every job
    final jobId = await startJob(fileSize: jpeg.length, copies: copies);
    await sendFile(jobId, jpeg, onProgress: onTransferProgress);
    await confirmJob(jobId);

    if (!wait) return PrintResult(jobId: jobId);

    final end = DateTime.now().add(timeout);
    var seenProcessing = false;
    JobInfo? info;
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      for (final ev in events()) {
        if (ev['method'] == 'event.big_data' && ev['params'] is Map) {
          lastTelemetry =
              Telemetry.fromParams((ev['params'] as Map).cast<String, dynamic>());
        }
      }
      info = await jobInfo(jobId);
      final st = await status();
      onStatus?.call(st);
      if (st.category == 'processing') seenProcessing = true;
      if (info.isFinished || (st.category == 'idle' && seenProcessing)) break;
    }
    return PrintResult(jobId: jobId, jobInfo: info, telemetry: lastTelemetry);
  }
}

class PrintResult {
  PrintResult({required this.jobId, this.jobInfo, this.telemetry});
  final int jobId;
  final JobInfo? jobInfo;
  final Telemetry? telemetry;
}
