import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mi_printer/mi_printer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_transport.dart';

/// Runs in a background isolate via `compute`.
Uint8List _prepare(Map<String, dynamic> args) =>
    preparePrintImage(args['bytes'] as Uint8List, fit: args['fit'] as String);

void main() => runApp(const MiPrinterApp());

const subStages = {
  'smart_sheet': '校正紙處理中（新相紙）',
  'decoding': '資料處理中',
  'pre_heat': '預熱中',
  'load_paper': '進紙中',
  'printing': '列印中',
};

class MiPrinterApp extends StatelessWidget {
  const MiPrinterApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Mi Printer',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _addressCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  final _log = <String>[];
  final _scrollCtrl = ScrollController();

  Printer? _printer;
  bool _connecting = false;
  Timer? _statusTimer;
  PrinterStatus? _status;
  Telemetry? _telemetry;

  Uint8List? _pickedImage;
  String _fit = 'cover';
  int _copies = 1;
  bool _printing = false;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    try {
      _printer?.close();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final sp = await SharedPreferences.getInstance();
    _addressCtrl.text = sp.getString('address') ?? '';
    _tokenCtrl.text = sp.getString('token') ?? '';
  }

  Future<void> _saveConfig() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('address', _addressCtrl.text.trim());
    await sp.setString('token', _tokenCtrl.text.trim());
    _logLine('已儲存設定');
  }

  void _logLine(String s) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    if (!mounted) return;
    setState(() => _log.add('[$t] $s'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Rc4Cipher get _cipher {
    final token = _tokenCtrl.text.trim();
    if (token.isNotEmpty) return Rc4Cipher.fromToken(token);
    throw PrinterException('請先填入 24-hex miio token');
  }

  Future<void> _connect() async {
    final address = _addressCtrl.text.trim();
    if (address.isEmpty) {
      _logLine('錯誤：請先填入印表機 MAC 位址');
      return;
    }
    setState(() => _connecting = true);
    try {
      _logLine('連線中…');
      final printer = Printer(AndroidRfcommTransport(address), _cipher);
      await printer.connect();
      final st = await printer.status();
      try {
        _printer?.close();
      } catch (_) {}
      setState(() {
        _printer = printer;
        _status = st;
      });
      _logLine('已連線：battery ${st.battery}%, ${st.category}/${st.subCategory}');
      _statusTimer?.cancel();
      _statusTimer =
          Timer.periodic(const Duration(seconds: 10), (_) => _pollStatus());
    } catch (e) {
      _logLine('連線失敗：$e');
      try {
        await _printer?.close();
      } catch (_) {}
      setState(() => _printer = null);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    _statusTimer?.cancel();
    try {
      await _printer?.close();
    } catch (_) {}
    setState(() {
      _printer = null;
      _status = null;
    });
    _logLine('已斷線');
  }

  Future<void> _pollStatus() async {
    final p = _printer;
    if (p == null || !p.isConnected) return;
    try {
      for (final ev in p.events()) {
        if (ev['method'] == 'event.big_data' && ev['params'] is Map) {
          final tm = Telemetry.fromParams(
              (ev['params'] as Map).cast<String, dynamic>());
          setState(() => _telemetry = tm);
          _logLine('事件：total.printed=${tm.printedTotal}');
        }
      }
      final st = await p.status();
      setState(() => _status = st);
    } catch (e) {
      _logLine('狀態更新失敗（連線可能已斷）：$e');
      _statusTimer?.cancel();
      setState(() => _printer = null);
    }
  }

  Future<void> _retime() async {
    final p = _printer;
    if (p == null) return;
    await p.retime();
    _logLine('已發送 retime（重置自動關機計時器）');
  }

  Future<void> _deviceInfo() async {
    final p = _printer;
    if (p == null) return;
    try {
      final info = await p.deviceInfo();
      _logLine('裝置：fw=${info['fw_ver']} mac=${info['mac']} did=${info['did']}');
    } catch (e) {
      _logLine('讀取裝置資訊失敗：$e');
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 95);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _pickedImage = Uint8List.fromList(bytes));
    _logLine('已選擇圖片 ${bytes.length ~/ 1024} KB');
  }

  Future<void> _print() async {
    final p = _printer;
    final src = _pickedImage;
    if (p == null || src == null || _printing) return;
    setState(() {
      _printing = true;
      _progress = '準備中…';
    });
    try {
      final jpeg = await compute(_prepare, {'bytes': src, 'fit': _fit});
      _logLine('影像已處理：${jpeg.length ~/ 1024} KB (1040x1560, $_fit)');
      final r = await p.printImage(
        jpeg,
        copies: _copies,
        onTransferProgress: (sent, total) {
          if (!mounted) return;
          setState(() => _progress = '傳輸 $sent/$total 塊');
          if (sent % 40 == 0 || sent == total) {
            _logLine('傳輸 $sent/$total');
          }
        },
        onStatus: (st) {
          if (!mounted) return;
          setState(() {
            _status = st;
            _progress =
                '${st.category}/${st.subCategory}${subStages[st.subCategory] != null ? '（${subStages[st.subCategory]}）' : ''}';
          });
        },
      );
      final ji = r.jobInfo;
      _logLine(
          '完成 job ${r.jobId}，state=${ji?.jobState}，print_time=${ji?.printTimeMs}ms');
      if (r.telemetry?.printedTotal != null) {
        _logLine('印表機終身列印：${r.telemetry!.printedTotal} 張');
      }
      setState(() => _progress = '完成 ✔');
    } catch (e) {
      _logLine('列印失敗：$e');
      setState(() => _progress = '失敗');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _printer != null && _printer!.isConnected;
    return Scaffold(
      appBar: AppBar(title: const Text('Mi Portable Photo Printer')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('設定'),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _addressCtrl,
                decoration: const InputDecoration(
                    labelText: 'MAC 位址', hintText: 'F0:13:C1:3F:63:94'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _saveConfig, child: const Text('儲存')),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'miio token（24 hex）',
              helperText: '從 Mi Cloud / Home Assistant 取得，僅存在本機',
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton(
              onPressed: _connecting ? null : (connected ? _disconnect : _connect),
              child: Text(_connecting
                  ? '連線中…'
                  : connected
                      ? '斷線'
                      : '連線'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: connected ? _deviceInfo : null,
              child: const Text('裝置資訊'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: connected ? _retime : null,
              child: const Text('retime'),
            ),
          ]),
          const SizedBox(height: 16),
          _section('狀態'),
          _statusCard(connected),
          const SizedBox(height: 16),
          _section('列印'),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.image),
              label: const Text('選擇圖片'),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _fit,
              items: const [
                DropdownMenuItem(value: 'cover', child: Text('cover（填滿裁切）')),
                DropdownMenuItem(value: 'contain', child: Text('contain（完整留白）')),
                DropdownMenuItem(value: 'stretch', child: Text('stretch（拉伸）')),
              ],
              onChanged: (v) => setState(() => _fit = v ?? 'cover'),
            ),
          ]),
          if (_pickedImage != null) ...[
            const SizedBox(height: 8),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 180,
                  child: AspectRatio(
                    aspectRatio: 1040 / 1560,
                    child: Image.memory(_pickedImage!,
                        fit: _fit == 'cover'
                            ? BoxFit.cover
                            : _fit == 'contain'
                                ? BoxFit.contain
                                : BoxFit.fill),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Text('份數：$_copies'),
            IconButton(
              onPressed: _copies > 1 ? () => setState(() => _copies--) : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            IconButton(
              onPressed: _copies < 9 ? () => setState(() => _copies++) : null,
              icon: const Icon(Icons.add_circle_outline),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: connected && _pickedImage != null && !_printing
                  ? _print
                  : null,
              icon: const Icon(Icons.print),
              label: Text(_printing ? '列印中…' : '列印'),
            ),
          ]),
          if (_progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(_progress),
              ]),
            ),
          const SizedBox(height: 16),
          _section('記錄'),
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(8),
            child: ListView.builder(
              controller: _scrollCtrl,
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );

  Widget _statusCard(bool connected) {
    final st = _status;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: st == null
            ? Text(connected ? '讀取中…' : '未連線')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      (st.battery ?? 0) > 20
                          ? Icons.battery_full
                          : Icons.battery_alert,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text('電池 ${st.battery ?? '?'}%'),
                    const SizedBox(width: 16),
                    Text('狀態：${st.category} / ${st.subCategory}'
                        '${subStages[st.subCategory] != null ? '（${subStages[st.subCategory]}）' : ''}'),
                  ]),
                  if (st.error != 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('⚠️ error=${st.error}',
                          style: const TextStyle(color: Colors.red)),
                    ),
                  if (st.timeLeftMs != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                          '約 ${(st.timeLeftMs! / 60000).toStringAsFixed(1)} 分鐘後自動關機'),
                    ),
                  if (_telemetry?.printedTotal != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('終身列印：${_telemetry!.printedTotal} 張'),
                    ),
                ],
              ),
      ),
    );
  }
}
