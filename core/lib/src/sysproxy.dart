import 'dart:convert';
import 'dart:io';

import 'durable.dart';

/// Where the OS-wide proxy is set and put back: the seam for platforms (Windows registry,
/// [SystemProxy]; [NoSystemProxy] where there is no such thing, e.g. Android, which uses TUN).
abstract interface class SystemProxyBackend {
  /// Whether the core has set the proxy and not yet put the previous one back.
  bool get isSet;

  /// Points the system proxy at 127.0.0.1:[port] (the previous values saved first); a warning
  /// to show the user, or null.
  Future<String?> enable(int port);

  /// Puts the previous system proxy back; nothing to do when [isSet] is false.
  Future<void> restore();
}

/// For platforms without a system proxy: never set, so nothing to restore.
class NoSystemProxy implements SystemProxyBackend {
  @override
  bool get isSet => false;

  @override
  Future<String?> enable(int port) async => 'System proxy is not available on this platform';

  @override
  Future<void> restore() async {}
}

/// Windows system proxy (WinINet, per user) pointed at the mixed inbound.
///
/// Set by the core, not by sing-box's `set_system_proxy`: sing-box undoes it only on a
/// graceful exit, and a killed process would leave the user without internet. The
/// previous values are saved to [stateFile] first and put back by [restore] — also on
/// the next start after a crash.
class SystemProxy implements SystemProxyBackend {
  SystemProxy(this.stateFile);

  final File stateFile;
  static const _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _names = ['ProxyEnable', 'ProxyServer', 'ProxyOverride'];
  static final _bypass = ['localhost', '127.*', '10.*', for (var i = 16; i < 32; i++) '172.$i.*', '192.168.*', '<local>'].join(';');

  @override
  bool get isSet => stateFile.existsSync();

  /// Returns a warning when a PAC script (AutoConfigURL, typical for corporate
  /// networks) is configured: Windows asks it before the manual proxy.
  @override
  Future<String?> enable(int port) async {
    if (!Platform.isWindows) throw UnsupportedError('System proxy is only done on Windows for now');
    if (!isSet) {
      final saved = {for (final n in _names) n: await _query(n)};
      await stateFile.parent.create(recursive: true);
      await writeFileDurable(stateFile, jsonEncode(saved));
    }
    await _set('ProxyServer', 'REG_SZ', '127.0.0.1:$port');
    await _set('ProxyOverride', 'REG_SZ', _bypass);
    await _set('ProxyEnable', 'REG_DWORD', '1');
    final pac = await _query('AutoConfigURL');
    return pac == null ? null : 'A PAC script is set (${pac['value']}) — it may take priority over the system proxy';
  }

  @override
  Future<void> restore() async {
    if (!isSet || !Platform.isWindows) return;
    Map<String, dynamic> saved;
    try {
      saved = (jsonDecode(await stateFile.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      // The saved values are unreadable (a power cut before they reached the disk): the
      // previous ones are lost. The registry is left as it is — whose proxy is set there now
      // cannot be told (another client may own it), and switching it off would break that.
      await stateFile.delete();
      return;
    }
    for (final n in _names) {
      final v = saved[n] as Map?;
      if (v == null) {
        await Process.run('reg', ['delete', _key, '/v', n, '/f']);
      } else {
        await _set(n, v['type'] as String, _regValue(v['type'] as String, v['value'] as String));
      }
    }
    await stateFile.delete();
  }

  // reg query prints DWORDs as 0x1; reg add wants a decimal number.
  static String _regValue(String type, String v) => type == 'REG_DWORD' && v.startsWith('0x') ? '${int.parse(v.substring(2), radix: 16)}' : v;

  Future<void> _set(String name, String type, String value) async {
    final r = await Process.run('reg', ['add', _key, '/v', name, '/t', type, '/d', value, '/f']);
    if (r.exitCode != 0) throw ProcessException('reg', ['add', name], '${r.stderr}', r.exitCode);
  }

  Future<Map<String, String>?> _query(String name) async {
    final r = await Process.run('reg', ['query', _key, '/v', name]);
    if (r.exitCode != 0) return null;
    final m = RegExp('^\\s+$name\\s+(REG_\\w+)\\s*(.*)\$', multiLine: true).firstMatch('${r.stdout}');
    return m == null ? null : {'type': m[1]!, 'value': m[2]!.trim()};
  }
}
