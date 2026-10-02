import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/platform_seams.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The core runs inside the app: its data dir and this platform's seams (sing-box process or
  // libbox, system proxy) are chosen in platform_seams.dart; the host starts it (init) in the app.
  final host = await openCoreHost();
  runApp(JormungandApp(coreHost: host));
}
