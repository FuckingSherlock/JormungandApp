// The Events filter starts with the types in defaultOffTypes switched off (sub/diverged: still journaled and in Raw).
// count and offCats measure the difference from that default, so a fresh filter counts nothing and reset() goes
// back to the default, not to empty.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> ev(int id, String cat, String type, {Map<String, dynamic> data = const {}}) =>
    {'id': id, 'at': 0, 'cat': cat, 'type': type, 'level': 'info', 'own': false, 'data': data};

EventRecord e(Map<String, dynamic> m) => EventRecord.fromJson(m);

String noText(EventRecord x) => '';

void main() {
  final diverged = e(ev(1, 'sub', 'diverged', data: {'source': 's1'}));
  final updated = e(ev(2, 'sub', 'updated', data: {'source': 's1', 'total': 3}));

  test('defaultOffTypes is sub/diverged, and the filter starts with exactly that switched off', () {
    expect(defaultOffTypes, {'sub/diverged'});
    final f = EventFilter();
    expect(f.off, defaultOffTypes);
    expect(f.visible(diverged, showOwn: false, text: noText), isFalse, reason: 'hidden by default');
    expect(f.visible(updated, showOwn: false, text: noText), isTrue, reason: 'the other sub types are shown');
  });

  test('a fresh filter counts nothing and has no category off', () {
    final f = EventFilter();
    expect(f.count, 0);
    expect(f.offCats, isEmpty);
  });

  test('the filter gets its own copy of the default: changing it leaves defaultOffTypes and new filters alone', () {
    final f = EventFilter()..off.add('conn/lost');
    expect(f.off, containsAll(['sub/diverged', 'conn/lost']));
    expect(defaultOffTypes, {'sub/diverged'});
    expect(EventFilter().off, {'sub/diverged'});
  });

  test('switching sub/diverged on counts its category once; switching it back off is the default again', () {
    final f = EventFilter()..toggleType('sub/diverged');
    expect(f.visible(diverged, showOwn: false, text: noText), isTrue);
    expect(f.count, 1);
    expect(f.offCats.map((c) => c.$1), ['sub']);
    f.toggleType('sub/diverged');
    expect(f.count, 0);
    expect(f.offCats, isEmpty);
  });

  test('switching another type off counts on top of the default; a second type of the same category does not add', () {
    final f = EventFilter()..toggleType('sub/diverged')..toggleType('conn/lost');
    expect(f.count, 2);
    expect(f.offCats.map((c) => c.$1).toList()..sort(), ['conn', 'sub']);
    f.toggleType('sub/updated');
    expect(f.count, 2, reason: 'sub is still one category');
  });

  test('reset() goes back to the default: sub/diverged hidden again, count 0', () {
    final f = EventFilter()
      ..toggleType('sub/diverged')
      ..toggleType('conn/lost')
      ..toggleType('sub/updated');
    expect(f.count, greaterThan(0));
    f.reset();
    expect(f.off, defaultOffTypes);
    expect(f.visible(diverged, showOwn: false, text: noText), isFalse);
    expect(f.count, 0);
    expect(f.offCats, isEmpty);
  });
}
