/// A node's server name that does not exist (docs/rules.md §6, docs/failures.md → «Имя сервера узла не существует»):
/// [AddressResolver.onNameMissing] is one observation, not a verdict. The verdict «the name is missing» is made by a
/// re-check one minute later (the same system chain, [recheck]); only when it says the same ([confirm]) the node is
/// dead. One check per host in flight (the pending entry); an open verdict is closed only by a new fact — the name
/// resolves ([resolved]) or the node answers on the ladder — and a repeat of «missing» while it stands is only counted
/// ([repeat]), never a new check and never dropped.
library;

import 'dart:async';

import 'address_book.dart';

class _Pending {
  _Pending(this.host);
  final String host;
  Timer? timer;

  /// The re-check is running / the verdict is being made.
  bool checking = false, confirming = false;

  /// Some lookup of the re-check said «the name does not exist».
  bool sawMissing = false;
  int tries = 0;
}

class NameMissingWatch {
  NameMissingWatch({
    required this.timer,
    required this.recheck,
    required this.confirm,
    required this.repeat,
    required this.cleared,
    required this.log,
    this.after = const Duration(minutes: 1),
    this.maxTries = 5,
  });

  final Timer Function(Duration, void Function()) timer;

  /// Resolves [host] again through the system chain: an entry = it resolves now. While it runs, [missing] calls
  /// (from the lookup's own report) mean the chain said «does not exist» once more.
  final Future<Object?> Function(String host) recheck;

  /// The re-check confirmed: make the verdict (event, ladder). True = it stands (kept open until a fact closes it).
  final Future<bool> Function(String host) confirm;

  /// A report of «missing» while the verdict stands: counted on its event.
  final Future<void> Function(String host) repeat;

  /// An open verdict was closed by [reason] (`resolved`, `node answered`).
  final void Function(String host, String reason) cleared;
  final void Function(String level, String text) log;

  /// How long after the first report the re-check is made; how many re-checks in all while they are inconclusive
  /// (the DNS itself was silent: a timeout is evidence, not a verdict).
  Duration after;
  int maxTries;

  final _pending = <String, _Pending>{};
  final _open = <String>{};
  bool _disposed = false;

  bool isPending(String host) => _pending.containsKey(AddressBook.key(host));
  bool isOpen(String host) => _open.contains(AddressBook.key(host));

  /// A lookup found nobody who knows [host] (every server that answered said NXDOMAIN / empty).
  void missing(String host) {
    if (_disposed) return;
    final k = AddressBook.key(host);
    if (_open.contains(k)) {
      unawaited(repeat(host));
      return;
    }
    final p = _pending[k];
    if (p != null) {
      if (p.checking) p.sawMissing = true; // the re-check's own answer
      return;
    }
    log('info', 'address: $host: the name does not exist; asked again in ${after.inSeconds} s before it is called missing');
    _pending[k] = _Pending(host)..timer = timer(after, () => unawaited(_check(k)));
  }

  /// A fact that closes the verdict: the name resolved ([reason] `resolved`) or the node answered.
  void resolved(String host, {String reason = 'resolved'}) {
    final k = AddressBook.key(host);
    final p = _pending.remove(k);
    p?.timer?.cancel();
    if (p != null && !p.confirming) log('info', 'address: $host: the name resolves, no longer under suspicion');
    if (_open.remove(k)) cleared(host, reason);
  }

  Future<void> _check(String k) async {
    final p = _pending[k];
    if (p == null || p.checking || _disposed) return;
    p.checking = true;
    p.sawMissing = false;
    p.tries++;
    Object? found;
    try {
      found = await recheck(p.host);
    } catch (_) {}
    if (_disposed || _pending[k] != p) return; // resolved meanwhile: [resolved] has cleaned up
    p.checking = false;
    if (found != null) {
      _pending.remove(k);
      return;
    }
    if (p.sawMissing) {
      p.confirming = true;
      var stands = false;
      try {
        stands = await confirm(p.host);
      } catch (e) {
        log('warn', 'address: ${p.host}: the verdict could not be made: $e');
      }
      if (_disposed) return;
      if (_pending[k] == p) {
        _pending.remove(k);
        if (stands) _open.add(k);
      } else if (stands) {
        cleared(p.host, 'resolved'); // the name resolved while the verdict was made: undo it
      }
      return;
    }
    if (p.tries >= maxTries) {
      _pending.remove(k);
      log('warn', 'address: ${p.host}: the re-check could not tell (${p.tries} tries, the DNS gave no clear answer): left alone until the next lookup');
      return;
    }
    log('info', 'address: ${p.host}: the re-check could not tell (no clear answer from the DNS), again in ${after.inSeconds} s');
    p.timer = timer(after, () => unawaited(_check(k)));
  }

  void dispose() {
    _disposed = true;
    for (final p in _pending.values) {
      p.timer?.cancel();
    }
    _pending.clear();
    _open.clear();
  }
}
