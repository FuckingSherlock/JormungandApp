// planCheckers (config.dart): the backup check URLs a plan asks for.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

void main() {
  group('planCheckers', () {
    test('missing everywhere: defaultCheckers', () {
      expect(planCheckers({}), defaultCheckers);
    });

    test('auto.checkers []: none, even if urlTest.checkers has some', () {
      expect(planCheckers({
        'auto': {'checkers': []},
        'urlTest': {
          'checkers': ['https://a.example/'],
        },
      }), isEmpty);
    });

    test('auto.checkers wins over urlTest.checkers when both are set', () {
      expect(
          planCheckers({
            'auto': {
              'checkers': ['https://a.example/'],
            },
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          ['https://a.example/']);
    });

    test('no auto.checkers: falls back to urlTest.checkers', () {
      expect(
          planCheckers({
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          ['https://b.example/']);
    });

    test('urlTest.checkers []: none', () {
      expect(
          planCheckers({
            'urlTest': {'checkers': []},
          }),
          isEmpty);
    });

    test('non-string and empty entries are dropped, from either key', () {
      expect(
          planCheckers({
            'auto': {
              'checkers': ['https://a.example/', 42, '', null, 'https://b.example/'],
            },
          }),
          ['https://a.example/', 'https://b.example/']);
    });

    test('auto.checkers present but not a list: defaultCheckers (?? does not fall through to urlTest)', () {
      expect(
          planCheckers({
            'auto': {'checkers': 'oops'},
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          defaultCheckers);
    });
  });

  test('AutoSettings.fromPlan reads checkers via planCheckers', () {
    final a = AutoSettings.fromPlan({
      'auto': {
        'checkers': ['https://a.example/'],
      },
    });
    expect(a.checkers, ['https://a.example/']);

    final b = AutoSettings.fromPlan({});
    expect(b.checkers, defaultCheckers);
  });
}
