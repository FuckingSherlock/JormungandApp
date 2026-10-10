// The outside-tunnel registry (core/lib/src/outside_tunnel.dart) against the app's sources: Dart in
// app/lib and the Kotlin overlay (the source of app/android). A file that opens a connection, a
// process or a libbox instance and is not registered fails here, so that code which has to work
// outside the tunnel cannot be added (or ported from the PC version) and forgotten. The scanner is
// the core's (core/test/outside_tunnel_scan.dart); the core's own sources are checked by
// core/test/outside_tunnel_test.dart. Failure messages say what to do.
import 'package:flutter_test/flutter_test.dart';

import '../../core/test/outside_tunnel_scan.dart';

void main() {
  final root = repoRoot();

  test('every Dart file of the app that opens a connection or a process is registered, and every registered one still does', () {
    final problems = scopeProblems(root, appDartScope);
    expect(problems, isEmpty, reason: '\n${problems.join('\n\n')}');
  });

  test('every Kotlin file that makes sockets, resolvers, libbox instances or network callbacks is registered, and every registered one still does', () {
    final problems = scopeProblems(root, appKotlinScope);
    expect(problems, isEmpty, reason: '\n${problems.join('\n\n')}');
  });

  test('the scan is not blind: the known Android files are found', () {
    final found = scanScope(root, appKotlinScope).keys.toSet();
    expect(
      found,
      containsAll([
        'app/android_overlay/kotlin/LocalResolver.kt.tmpl',
        'app/android_overlay/kotlin/LibboxPlatform.kt.tmpl',
        'app/android_overlay/kotlin/VpnChannel.kt.tmpl',
        'app/android_overlay/kotlin/JormungandVpnService.kt.tmpl',
      ]),
    );
    expect(scanScope(root, appDartScope).keys, contains('app/lib/platform/files_channel.dart'));
  });
}
