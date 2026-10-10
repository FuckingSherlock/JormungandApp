import 'dart:convert';

/// Masks what must not leave the device in a report: credentials and tokens, in free text (the raw
/// log, event data) and in structured values (docs/logs.md → Маскирование).
///
/// A value becomes `<kind#N>`: the same value always gets the same number, so "the same
/// subscription" stays recognisable across lines without being readable. [counts] says how many
/// replacements each kind made, [total] all of them. Domains, IP addresses, server names, ports and
/// package names stay — the local report is for the developer to read, not an anonymised statistic.
///
/// Kinds: `url` (path and query of a web URL), `userinfo` (`user:pass@` of a web URL), `link` (the
/// credentials of a proxy share link), `uuid`, `secret` (a value named like one), `token` (Bearer,
/// bot / API tokens, long random strings).
///
/// [strict] (the report that is sent to the developers, docs/logs.md → Отправка) adds two kinds that the
/// local export keeps: `email` (an address anywhere in the text) and `path` (the user name inside a
/// home-directory path: `C:\Users\<name>\…`, `/home/<name>/…`). Domains, IPs and package names stay.
///
/// Running a result through again changes nothing (placeholders are left alone).
class Redactor {
  Redactor({this.strict = false});

  /// The sent report's mode: also e-mail addresses and the user name of home paths.
  final bool strict;

  final _seen = <String, Map<String, int>>{};

  /// Replacements made so far, by kind.
  final counts = <String, int>{};

  int get total => counts.values.fold(0, (a, b) => a + b);

  String _ph(String kind, String value) {
    final m = _seen.putIfAbsent(kind, () => <String, int>{});
    final n = m.putIfAbsent(value, () => m.length + 1);
    counts[kind] = (counts[kind] ?? 0) + 1;
    return '<$kind#$n>';
  }

  // an earlier pass's placeholder, or one of ours in this pass
  static final _placeholder = RegExp(r'^<[a-z]+#\d+>$');
  static bool _isPlaceholder(String s) => _placeholder.hasMatch(s);

  // ── structured values ──

  /// [v] (a JSON value) with its strings masked by [text] and the values of secret-named keys
  /// replaced whole. [free]: the strings are free text (the raw log, event data) — also the
  /// "looks like a token" rules; off for fixed fields (a commit hash must stay readable).
  Object? json(Object? v, {bool free = true}) {
    if (v is String) return text(v, free: free);
    if (v is List) return [for (final e in v) json(e, free: free)];
    if (v is Map) {
      return {
        for (final e in v.entries)
          '${e.key}': _secretKey('${e.key}') && _maskable(e.value) ? _ph('secret', jsonEncode(e.value)) : json(e.value, free: free),
      };
    }
    return v;
  }

  static bool _maskable(Object? v) => v is num || (v is String && v.isNotEmpty && !_isPlaceholder(v)) || v is Map || v is List;

  static const _secretKeys = {
    'password', 'passwd', 'pwd', 'pass', 'secret', 'token', 'accesstoken', 'refreshtoken', 'apikey', 'privatekey',
    'presharedkey', 'psk', 'pbk', 'authorization', 'obfspassword', 'authstr', 'hwid', 'uuid',
  };

  // `private_key`, `Private-Key`, `privateKey` → privatekey
  static bool _secretKey(String k) => _secretKeys.contains(k.toLowerCase().replaceAll(RegExp(r'[_\-]'), ''));

  // ── text ──

  // scheme://rest, up to a space, a quote or a closing bracket
  static final _urlRe = RegExp(r'''\b([A-Za-z][A-Za-z0-9+.\-]{1,15})://([^\s"'<>)\]}]+)''');
  static final _tailPunct = RegExp(r'[.,;:!?]+$');
  static final _b64Blob = RegExp(r'^[A-Za-z0-9+/_=\-]{16,}$');

  // query parameters of a share link whose value is a credential
  static const _secretParams = {
    'pbk', 'sid', 'password', 'pass', 'passwd', 'key', 'token', 'psk', 'auth', 'secret', 'uuid', 'obfs-password',
    'obfs_password', 'authstr', 'auth-str', 'auth_str', 'privatekey', 'private-key', 'private_key', 'publickey',
    'public-key', 'public_key',
  };

  static final _uuidRe = RegExp(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');

  // names that are a secret wherever they stand: `token: abc`, `"password": "abc"`, `api_key=abc`
  static final _kvRe = RegExp(
    r'''(?<![A-Za-z0-9])(["']?)(password|passwd|pwd|secret|token|(?:access|refresh|api|private|public|pre_?shared)[_-]?(?:token|key)|apikey|privatekey|psk|pbk|authorization|obfs[_-]?password|auth[_-]?str|hwid)\1(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s&,;"'}\]]+)''',
    caseSensitive: false,
  );

  // short names that are only a secret as `name=value` (`key=`, `sid=`, `pass=`): in prose they are words
  static final _kvEqRe = RegExp(r'''(?<![A-Za-z0-9.])(key|pass|sid|auth|uuid|short[_-]?id)=([^\s&,;"'}\]]+)''', caseSensitive: false);

  static final _bearerRe = RegExp(r'\bBearer(\s+)([A-Za-z0-9._~+/=\-]{8,})', caseSensitive: false);
  static final _botRe = RegExp(r'\b\d{8,10}:[A-Za-z0-9_\-]{35}\b');
  static final _apiTokenRe = RegExp(r'\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})\b');
  static final _longRe = RegExp(r'(?<![A-Za-z0-9_\-/.<#:@])[A-Za-z0-9_\-]{32,}={0,2}(?![A-Za-z0-9_\-])');
  static final _hexRe = RegExp(r'^[0-9a-f]+$');

  /// [s] with its secrets masked. [free] as in [json].
  String text(String s, {bool free = true}) {
    if (s.length < 6) return s;
    if (s.contains('://')) s = s.replaceAllMapped(_urlRe, _url);
    if (s.contains('-')) s = s.replaceAllMapped(_uuidRe, (m) => _ph('uuid', m[0]!.toLowerCase()));
    if (s.contains('earer') || s.contains('EARER')) {
      s = s.replaceAllMapped(_bearerRe, (m) => _isPlaceholder(m[2]!) ? m[0]! : 'Bearer${m[1]}${_ph('token', m[2]!)}');
    }
    if (s.contains(':') || s.contains('=')) {
      s = s.replaceAllMapped(_kvRe, (m) {
        final v = m[4]!, inner = _unquote(v);
        // `authorization: Bearer <token>`: the word is not the value
        if (inner.isEmpty || _isPlaceholder(inner) || inner.toLowerCase() == 'bearer') return m[0]!;
        return '${m[1]}${m[2]}${m[1]}${m[3]}${_quoteLike(v, _ph('secret', inner))}';
      });
    }
    if (s.contains('=')) {
      s = s.replaceAllMapped(_kvEqRe, (m) => _isPlaceholder(m[2]!) ? m[0]! : '${m[1]}=${_ph('secret', m[2]!)}');
    }
    if (free) {
      if (s.contains(':')) s = s.replaceAllMapped(_botRe, (m) => _ph('token', m[0]!));
      s = s.replaceAllMapped(_apiTokenRe, (m) => _ph('token', m[0]!));
      if (s.length >= 32) {
        s = s.replaceAllMapped(_longRe, (m) {
          final t = m[0]!;
          if (!t.contains(RegExp(r'[0-9]')) || !t.contains(RegExp(r'[A-Za-z]'))) return t; // a long word / number
          // a file digest, not a secret: a commit, SHA-1 / SHA-256 of a download
          if ((t.length == 40 || t.length == 64) && _hexRe.hasMatch(t)) return t;
          return _ph('token', t);
        });
      }
    }
    if (strict) s = _strictPass(s);
    return s;
  }

  // strict only: an e-mail address, the account name inside a home-directory path
  static final _emailRe = RegExp(r'(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b');
  static final _homeRe = RegExp(r'''([A-Za-z]:[\\/]+[Uu]sers[\\/]+|/home/|/Users/)([^\\/\s"'<>:]+)''');

  String _strictPass(String s) {
    if (s.contains('@')) s = s.replaceAllMapped(_emailRe, (m) => _ph('email', m[0]!.toLowerCase()));
    if (s.contains('sers') || s.contains('/home/')) {
      s = s.replaceAllMapped(_homeRe, (m) => '${m[1]}${_ph('path', m[2]!)}');
    }
    return s;
  }

  static String _unquote(String v) =>
      v.length >= 2 && (v.startsWith('"') && v.endsWith('"') || v.startsWith("'") && v.endsWith("'")) ? v.substring(1, v.length - 1) : v;

  // the placeholder in the quotes the value had
  static String _quoteLike(String v, String ph) =>
      v.length >= 2 && v.startsWith('"') && v.endsWith('"') ? '"$ph"' : v.length >= 2 && v.startsWith("'") && v.endsWith("'") ? "'$ph'" : ph;

  String _url(Match m) {
    final scheme = m[1]!;
    var rest = m[2]!;
    var punct = '';
    final p = _tailPunct.firstMatch(rest);
    if (p != null) {
      punct = p[0]!;
      rest = rest.substring(0, p.start);
    }
    if (rest.isEmpty) return m[0]!;
    final low = scheme.toLowerCase();
    final web = low == 'http' || low == 'https' || low == 'ws' || low == 'wss';
    return '$scheme://${web ? _webRest(rest) : _linkRest(rest)}$punct';
  }

  // host[:port] stays; `user:pass@` and the path / query / fragment go
  String _webRest(String rest) {
    final end = rest.indexOf(RegExp(r'[/?#]'));
    var authority = end < 0 ? rest : rest.substring(0, end);
    final tail = end < 0 ? '' : rest.substring(end);
    final at = authority.lastIndexOf('@');
    if (at >= 0) {
      final info = authority.substring(0, at);
      authority = '${_isPlaceholder(info) ? info : _ph('userinfo', info)}${authority.substring(at)}';
    }
    if (tail.isEmpty || tail == '/' || _isPlaceholder(tail.startsWith('/') ? tail.substring(1) : tail)) return '$authority$tail';
    return '$authority/${_ph('url', tail)}';
  }

  // a proxy share link: the credentials go, the endpoint, the transport parameters and the name stay
  String _linkRest(String rest) {
    var frag = '';
    final h = rest.indexOf('#');
    if (h >= 0) {
      frag = rest.substring(h);
      rest = rest.substring(0, h);
    }
    var query = '';
    final q = rest.indexOf('?');
    if (q >= 0) {
      query = rest.substring(q + 1);
      rest = rest.substring(0, q);
    }
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      final info = rest.substring(0, at);
      rest = '${_isPlaceholder(info) ? info : _ph('link', info)}${rest.substring(at)}';
    } else if (_b64Blob.hasMatch(rest)) {
      rest = _ph('link', rest); // vmess://, a legacy ss:// — the whole body is the account
    }
    if (query.isNotEmpty) {
      final parts = <String>[];
      for (final pair in query.split('&')) {
        final eq = pair.indexOf('=');
        if (eq <= 0) {
          parts.add(pair);
          continue;
        }
        final k = pair.substring(0, eq), v = pair.substring(eq + 1);
        final key = _safeDecode(k).toLowerCase();
        parts.add(_secretParams.contains(key) && v.isNotEmpty && !_isPlaceholder(v) ? '$k=${_ph('secret', v)}' : pair);
      }
      query = '?${parts.join('&')}';
    }
    return '$rest$query$frag';
  }

  static String _safeDecode(String s) {
    try {
      return Uri.decodeQueryComponent(s);
    } catch (_) {
      return s;
    }
  }
}
