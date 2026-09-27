// withCheckers (probe.dart): the test URL first, backup checkers only when it misses.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

void main() {
  group('withCheckers', () {
    test('the url answers: its ms, checkers never called', () async {
      final called = <String>[];
      Future<int> test(String u) async {
        called.add(u);
        return u == 'url' ? 42 : -1;
      }

      final ms = await withCheckers(test, 'url', ['a', 'b']);
      expect(ms, 42);
      expect(called, ['url']);
    });

    test('the url misses: every checker at once, the first that answers wins', () async {
      final called = <String>[];
      Future<int> test(String u) async {
        called.add(u);
        if (u == 'url') return -1;
        if (u == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return 10;
        }
        if (u == 'fast') return 5;
        return -1;
      }

      final ms = await withCheckers(test, 'url', ['slow', 'fast', 'dead']);
      expect(ms, 5, reason: 'the fast checker answered first');
      expect(called.toSet(), {'url', 'slow', 'fast', 'dead'}, reason: 'all checkers are tried at once, not one by one');
    });

    test('the url and every checker miss: -1', () async {
      Future<int> test(String u) async => -1;
      expect(await withCheckers(test, 'url', ['a', 'b']), -1);
    });

    test('a checker equal to the url is skipped', () async {
      final called = <String>[];
      Future<int> test(String u) async {
        called.add(u);
        return u == 'url' ? -1 : (u == 'b' ? 7 : -1);
      }

      final ms = await withCheckers(test, 'url', ['url', 'b']);
      expect(ms, 7);
      expect(called.where((u) => u == 'url').length, 1, reason: 'url tested once, not again as a checker');
    });

    test('no checkers: the url miss is the final answer', () async {
      Future<int> test(String u) async => -1;
      expect(await withCheckers(test, 'url', const []), -1);
    });

    test('a throwing checker counts as -1, not an unhandled error', () async {
      Future<int> test(String u) async {
        if (u == 'bad') throw StateError('boom');
        return u == 'ok' ? 3 : -1;
      }

      expect(await withCheckers(test, 'url', ['bad', 'ok']), 3);
    });

    test('every checker throws: -1, not an unhandled error', () async {
      Future<int> test(String u) async => u == 'url' ? -1 : throw StateError('boom: $u');
      expect(await withCheckers(test, 'url', ['a', 'b']), -1);
    });

    test('a throwing test of the url itself counts as -1, the checkers go on', () async {
      Future<int> test(String u) async => u == 'url' ? throw StateError('boom') : 5;
      expect(await withCheckers(test, 'url', ['a']), 5);
    });
  });
}
