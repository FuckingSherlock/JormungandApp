/// The DNS flags (docs/rules.md §6): every DNS server of the config ([DnsCandidate]) has a local rule set
/// whose file says whether the server is live. On matches every name, off matches none, and the DNS rules
/// take the first candidate of a side whose flag is on. sing-box watches the files, so rewriting one moves
/// the answers to another server with no restart and no API call (the open connections stay).
library;

import 'dart:io';

import 'durable.dart';
import 'routing.dart';

/// The rule set source of a flag: on = matches every name, off = a name no query has.
String dnsFlagJson(bool on) => on
    ? '{"version":3,"rules":[{"domain_regex":[".*"]}]}'
    : '{"version":3,"rules":[{"domain":["never.invalid"]}]}';

/// Where the flag writes are told (the core log: `logBook.note`).
typedef DnsFlagLog = void Function(String level, String text);

/// Writes the flag files of [candidates] (the directory is created), each on unless [on] says otherwise.
/// The core calls it before sing-box starts: a missing file stops sing-box from starting, so all of them must
/// exist; a file that cannot be written is an error (the start fails). [reason] (`connect`, `restart re-apply`,
/// `adopt`) is told with every write.
void writeDnsFlags(Iterable<DnsCandidate> candidates, {bool Function(DnsCandidate c)? on, String reason = '', DnsFlagLog? log}) {
  for (final c in candidates) {
    setDnsFlag(c, on?.call(c) ?? true, reason: reason, log: log, level: 'debug');
  }
}

/// Sets one flag (an atomic rewrite: the old file or the new one, never half of it). Every write is told to
/// [log] (at [level]) with the candidate, the state, the [reason] and the file; a failure is told as an error
/// and rethrown.
void setDnsFlag(DnsCandidate c, bool on, {String reason = '', DnsFlagLog? log, String level = 'info'}) {
  final f = File(c.flagPath);
  try {
    f.parent.createSync(recursive: true);
    writeFileDurableSync(f, dnsFlagJson(on));
  } catch (e) {
    log?.call('error', 'dns flag: ${c.id} (${c.side}) ${on ? 'on' : 'off'}${reason.isEmpty ? '' : ' ($reason)'}: not written to ${c.flagPath}: $e');
    rethrow;
  }
  log?.call(level, 'dns flag: ${c.id} (${c.side}) ${on ? 'on' : 'off'}${reason.isEmpty ? '' : ' ($reason)'}: written to ${c.flagPath}');
}
