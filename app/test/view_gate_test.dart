// A headless start has no view for runApp: the UI starts on the first of two signals (the view's
// metrics, the native "a window attached") and never twice.
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/view_gate.dart';

void main() {
  test('a view that is there: one run, however many signals follow', () {
    var runs = 0;
    final g = ViewGate(hasView: () => true, run: () => runs++);
    g.check();
    g.windowAttached();
    g.check();
    g.windowAttached();
    expect(runs, 1);
    expect(g.started, isTrue);
  });

  test('no view: nothing runs; metrics then window signal start it once', () {
    var view = false, runs = 0;
    final g = ViewGate(hasView: () => view, run: () => runs++);
    g.check();
    expect(runs, 0);
    view = true;
    g.check(); // the metrics path
    g.windowAttached(); // the native path, later
    g.check();
    expect(runs, 1);
  });

  test('the window signal comes first, the view reports in a moment later: runs once', () async {
    var view = false, runs = 0;
    final g = ViewGate(
      hasView: () => view,
      run: () => runs++,
      poll: const Duration(milliseconds: 10),
    );
    g.windowAttached();
    g.windowAttached(); // a second signal does not start a second poll
    expect(runs, 0);
    await Future<void>.delayed(const Duration(milliseconds: 35));
    view = true;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(runs, 1);
    g.check();
    expect(runs, 1, reason: 'the metrics path after the poll: idempotent');
  });

  test('a view that never comes: the poll gives up', () async {
    var checks = 0;
    final g = ViewGate(
      hasView: () {
        checks++;
        return false;
      },
      run: () => fail('no view'),
      poll: const Duration(milliseconds: 10),
      giveUp: const Duration(milliseconds: 50),
    );
    g.windowAttached();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final seen = checks;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(checks, seen, reason: 'stopped polling');
  });
}
