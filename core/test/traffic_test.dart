import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> conn(String id, {String net = 'tcp', List chains = const ['proxy'], int down = 0, int up = 0, String host = 'example.com'}) => {
      'id': id,
      'chains': chains,
      'download': down,
      'upload': up,
      'rule': 'final',
      'start': '2026-09-26T15:48:35+03:00',
      'metadata': {'network': net, 'host': host, 'destinationIP': '1.2.3.4', 'destinationPort': '443', 'processPath': r'C:\app\chrome.exe'},
    };

void main() {
  test('speed from counter deltas, connections resolved to the real server', () {
    final m = TrafficMeter();
    final proxies = {
      'proxies': {
        'proxy': {'now': 'proxy/s1::n7'},
        'entry': {'now': 'entry/s2::n1'},
      },
    };
    final first = m.sample({'downloadTotal': 1000, 'uploadTotal': 100, 'connections': [conn('a', down: 1000, up: 100)]}, proxies, 0);
    expect(first['down'], 0); // nothing to compare with yet
    expect(first['downTotal'], 1000);

    final s = m.sample({
      'downloadTotal': 3000,
      'uploadTotal': 300,
      'connections': [
        conn('a', chains: ['proxy/s1::n7', 'proxy'], down: 2500, up: 200),
        conn('b', net: 'udp', chains: ['direct'], down: 500, up: 100, host: ''),
      ],
    }, proxies, 2000);
    expect(s['down'], 1000);
    expect(s['up'], 100);
    expect([s['tcp'], s['udp']], [1, 1]);
    final a = (s['conns'] as List).first as Map;
    expect(a['out'], ['proxy/s1::n7', 'entry/s2::n1']);
    expect([a['downRate'], a['upRate']], [750, 50]);
    final b = (s['conns'] as List).last as Map;
    expect(b['out'], ['direct']);
    expect(b['host'], '1.2.3.4'); // no sniffed host: the address
    expect(b['downRate'], 250); // new since the last sample
  });

  test('a restarted sing-box never gives negative speed', () {
    final m = TrafficMeter();
    m.sample({'downloadTotal': 5000, 'uploadTotal': 500, 'connections': []}, null, 0);
    final s = m.sample({'downloadTotal': 10, 'uploadTotal': 1, 'connections': []}, null, 1000);
    expect([s['down'], s['up']], [0, 0]);
  });
}
