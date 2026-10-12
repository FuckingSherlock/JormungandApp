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

/// Writes the flag files of [candidates] (the directory is created), each on unless [on] says otherwise.
/// The core calls it with every flag on before sing-box starts: a missing file stops sing-box from
/// starting, so all of them must exist.
void writeDnsFlags(Iterable<DnsCandidate> candidates, {bool Function(DnsCandidate c)? on}) {
  for (final c in candidates) {
    setDnsFlag(c, on?.call(c) ?? true);
  }
}

/// Sets one flag (an atomic rewrite: the old file or the new one, never half of it).
void setDnsFlag(DnsCandidate c, bool on) {
  final f = File(c.flagPath);
  f.parent.createSync(recursive: true);
  writeFileDurableSync(f, dnsFlagJson(on));
}
