// NetSwitchTracker (docs/logs.md → Смена сети): when a network change is a net/switched, what its data holds,
// the provider lookup (wifi / ethernet only, only when enabled, cached by network id and public IP).
import 'dart:async';

import 'package:jormungand_core/src/netswitch.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime(2026, 10, 17, 12);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  late List<({String ip, String? org})?> answers; // consumed one per lookup; the last one repeats
  late int lookups;
  late bool enabled;
  late bool throwing;
  late NetSwitchTracker tr;

  setUp(() {
    answers = [(ip: '192.0.2.1', org: 'IspOne')];
    lookups = 0;
    enabled = true;
    throwing = false;
    tr = NetSwitchTracker(
      lookup: () async {
        lookups++;
        if (throwing) throw Exception('offline');
        return answers.length > 1 ? answers.removeAt(0) : answers.first;
      },
      providerEnabled: () => enabled,
      now: () => t0,
    );
  });

  // the switch with the provider lookup through (what the owner gets after `completed`)
  Future<Map<String, Object?>?> settled() async {
    final sw = tr.onSettled();
    if (sw == null) return null;
    return (await sw.completed) ?? sw.data;
  }

  Future<Map<String, Object?>?> settle(NetInfo? n, int s) {
    tr.onNetwork(n, at(s));
    return settled();
  }

  NetInfo wifi(String id, {bool? metered}) => NetInfo(type: 'wifi', id: id, operator: null, metered: metered);
  NetInfo mobile({String id = 'cell', String? op = 'Operator'}) => NetInfo(type: 'mobile', id: id, operator: op, metered: true);
  Map from(Map<String, Object?> d) => d['from'] as Map;
  Map to(Map<String, Object?> d) => d['to'] as Map;

  test('the first network after start is not a switch', () async {
    expect(await settle(wifi('A'), 0), isNull);
  });

  test('the type changes: a switch, from / to by type, metered carried', () async {
    await settle(wifi('A'), 0);
    final d = (await settle(mobile(), 10))!;
    expect(from(d)['type'], 'wifi');
    expect(to(d)['type'], 'mobile');
    expect(to(d)['metered'], true);
    expect(d.containsKey('downMs'), isFalse, reason: 'there was never no network between');
  });

  test('the id changes with the same type: a switch', () async {
    await settle(wifi('A'), 0);
    final d = (await settle(wifi('B'), 10))!;
    expect([from(d)['type'], to(d)['type']], ['wifi', 'wifi']);
  });

  test('the same network again (no change) and a settle with nothing new: nothing', () async {
    await settle(wifi('A'), 0);
    expect(await settle(wifi('A'), 5), isNull);
    expect(await settled(), isNull);
    await settle(mobile(), 10);
    expect(await settled(), isNull, reason: 'a switch is reported once');
  });

  test('a drop and a return to the same network is not a switch', () async {
    await settle(wifi('A'), 0);
    tr.onNetwork(null, at(5));
    tr.onNetwork(wifi('A'), at(9));
    expect(await settled(), isNull);
  });

  test('a drop, then another network: a switch with downMs = the time without a network', () async {
    await settle(wifi('A'), 0);
    tr.onNetwork(null, at(10));
    tr.onNetwork(mobile(), at(13));
    final d = (await settled())!;
    expect(d['downMs'], 3000);
    expect(from(d)['type'], 'wifi');
    expect(to(d)['type'], 'mobile');
  });

  test('the comparison is against the last SETTLED network: A -> B -> A before it settled is no switch', () async {
    await settle(wifi('A'), 0);
    tr.onNetwork(wifi('B'), at(5));
    tr.onNetwork(wifi('A'), at(6));
    expect(await settled(), isNull);
  });

  test('no network at settle time: nothing to report', () async {
    await settle(wifi('A'), 0);
    expect(await settle(null, 5), isNull);
  });

  group('provider', () {
    test('the switch is known at once, without the new provider; the lookup ends in `completed`', () async {
      final gate = Completer<({String ip, String? org})?>();
      tr = NetSwitchTracker(lookup: () => gate.future, providerEnabled: () => true);
      tr.onNetwork(mobile(), at(0));
      tr.onSettled();
      tr.onNetwork(wifi('A'), at(10));
      final sw = tr.onSettled()!; // the lookup is still waiting
      expect(to(sw.data)['type'], 'wifi');
      expect(to(sw.data).containsKey('provider'), isFalse);
      gate.complete((ip: '192.0.2.1', org: 'IspOne'));
      expect(to((await sw.completed)!)['provider'], 'IspOne');
    });

    test('nothing to add (no lookup, mobile): completed is null', () async {
      await settle(wifi('A'), 0);
      tr.onNetwork(mobile(), at(10));
      expect(await tr.onSettled()!.completed, isNull);
    });

    test('the provider of the network left is the one seen on it, also when the first lookup was still running', () async {
      await settle(wifi('A'), 0); // the first network: its provider is looked up and remembered
      answers = [(ip: '198.51.100.7', org: 'IspTwo')];
      final d = (await settle(wifi('B'), 10))!;
      expect(from(d)['provider'], 'IspOne');
      expect(to(d)['provider'], 'IspTwo');
    });

    test('wifi: the organisation of the direct public IP; looked up after the network settles', () async {
      await settle(mobile(), 0);
      final before = lookups;
      final d = (await settle(wifi('A'), 10))!;
      expect(to(d)['provider'], 'IspOne');
      expect(lookups, greaterThan(before));
    });

    test('ethernet gets a provider too', () async {
      await settle(mobile(), 0);
      final d = (await settle(NetInfo(type: 'ethernet', id: 'E', operator: null, metered: false), 10))!;
      expect(to(d)['provider'], 'IspOne');
    });

    test('mobile: the operator of the platform, no lookup, no provider', () async {
      await settle(wifi('A'), 0);
      lookups = 0;
      final d = (await settle(mobile(op: 'MTS'), 10))!;
      expect(to(d)['operator'], 'MTS');
      expect(to(d).containsKey('provider'), isFalse);
      expect(lookups, 0);
    });

    test('mobile without an operator: the key is absent, not null', () async {
      await settle(wifi('A'), 0);
      final d = (await settle(mobile(op: null), 10))!;
      expect(to(d).containsKey('operator'), isFalse);
    });

    test('the setting off: only the type, no lookup', () async {
      enabled = false;
      await settle(mobile(), 0);
      lookups = 0;
      final d = (await settle(wifi('A'), 10))!;
      expect(to(d)['type'], 'wifi');
      expect(to(d).containsKey('provider'), isFalse);
      expect(lookups, 0);
    });

    test('the setting is read at the time of the switch, not once', () async {
      enabled = false;
      await settle(mobile(), 0);
      enabled = true;
      final d = (await settle(wifi('A'), 10))!;
      expect(to(d)['provider'], 'IspOne');
    });

    test('a lookup that fails or finds no organisation: no provider, the switch is still reported', () async {
      await settle(mobile(), 0);
      throwing = true;
      final d = (await settle(wifi('A'), 10))!;
      expect(to(d)['type'], 'wifi');
      expect(to(d).containsKey('provider'), isFalse);

      throwing = false;
      answers = [null];
      final d2 = (await settle(wifi('B'), 20))!;
      expect(to(d2).containsKey('provider'), isFalse);

      answers = [(ip: '192.0.2.9', org: null)];
      final d3 = (await settle(wifi('C'), 30))!;
      expect(to(d3).containsKey('provider'), isFalse);
    });

    test('cached by network id while the public IP is the same; a new IP means a new organisation', () async {
      await settle(mobile(), 0);
      await settle(wifi('A'), 10); // IspOne, 192.0.2.1
      await settle(mobile(), 20);

      // back to A, the same public IP, the answer carries no organisation: the cached one stays
      answers = [(ip: '192.0.2.1', org: null)];
      var d = (await settle(wifi('A'), 30))!;
      expect(to(d)['provider'], 'IspOne');

      // back to A on another public IP: the old name is not trusted
      await settle(mobile(), 40);
      answers = [(ip: '198.51.100.5', org: 'IspTwo')];
      d = (await settle(wifi('A'), 50))!;
      expect(to(d)['provider'], 'IspTwo');
    });

    test('a new network id is looked up on its own (not served from the cache of another)', () async {
      await settle(mobile(), 0);
      await settle(wifi('A'), 10);
      answers = [(ip: '198.51.100.7', org: 'IspThree')];
      final d = (await settle(wifi('B'), 20))!;
      expect(to(d)['provider'], 'IspThree');
    });
  });
}
