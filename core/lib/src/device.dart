import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'durable.dart';

/// What a subscription with "Send X-HWID" on tells the provider about this device, as
/// Remnawave reads it: `x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model` (panels limit
/// devices per user by the id). The id is random, made once and kept in
/// `<dataDir>/device.json`, so the provider sees one device across restarts; nothing in it
/// comes from the hardware. (Flutter: the same headers, model / OS from device_info_plus.)
Future<Map<String, String>> deviceHeaders(String dataDir) async {
  final f = File(p.join(dataDir, 'device.json'));
  String? id;
  try {
    id = (jsonDecode(await f.readAsString()) as Map)['id'] as String?;
  } catch (_) {}
  if (id == null || id.isEmpty) {
    final r = Random.secure();
    id = [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    await f.parent.create(recursive: true);
    await writeFileDurable(f, jsonEncode({'id': id}));
  }
  return {
    'x-hwid': id,
    'x-device-os': _ascii(_osName()),
    'x-ver-os': _ascii(_osVersion()),
    'x-device-model': _ascii(await _model()),
  };
}

// Header values must stay printable ASCII.
String _ascii(String s) {
  final t = s.replaceAll(RegExp(r'[^\x20-\x7e]'), '').trim();
  return t.isEmpty ? 'unknown' : t;
}

String _osName() => switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' => 'iOS',
      final o => o,
    };

/// `"Windows 11 Pro" 10.0 (Build 26200)` → `10.0.26200`; elsewhere the first version number.
String _osVersion() {
  final v = Platform.operatingSystemVersion;
  final win = RegExp(r'(\d+\.\d+)\s*\(Build (\d+)').firstMatch(v);
  if (win != null) return '${win[1]}.${win[2]}';
  return RegExp(r'\d+(\.\d+)+').stringMatch(v) ?? v;
}

const _placeholders = {'system product name', 'to be filled by o.e.m.', 'default string', 'none', ''};

/// The computer's model name from the firmware (e.g. `ThinkPad X1 Carbon`); `PC` when the
/// board has a placeholder there.
Future<String> _model() async {
  String? m;
  try {
    if (Platform.isWindows) {
      final r = await Process.run('reg', ['query', r'HKLM\HARDWARE\DESCRIPTION\System\BIOS', '/v', 'SystemProductName']);
      m = RegExp(r'REG_SZ\s+(.+)').firstMatch('${r.stdout}')?[1]?.trim();
    } else if (Platform.isLinux) {
      m = (await File('/sys/class/dmi/id/product_name').readAsString()).trim();
    } else if (Platform.isMacOS) {
      m = '${(await Process.run('sysctl', ['-n', 'hw.model'])).stdout}'.trim();
    }
  } catch (_) {}
  return m == null || _placeholders.contains(m.toLowerCase()) ? 'PC' : m;
}
