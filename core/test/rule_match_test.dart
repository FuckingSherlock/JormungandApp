// The matcher (rule_match.dart): does a user rule catch a host[:port], and which rules of
// own / per-app lists catch it. Pure: decidable groups only; anything else is a miss.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

/// One condition group: `{not, v: {field: [values]}}`.
Map<String, dynamic> _card(
  Map<String, List<String>> v, {
  bool not = false,
  bool? flag,
}) => {'not': not, 'v': v, 'flag': ?flag};

/// A rule built from JSON, the way the catalog loads it.
UserRule _rule(
  Map<String, dynamic> groups, {
  String id = 'r1',
  bool enabled = true,
  Map<String, dynamic>? composite,
}) => UserRule.fromJson({
  'id': id,
  'name': id,
  'enabled': enabled,
  'action': 'proxy',
  'groups': groups,
  'composite': ?composite,
});

UserRule _domain(
  Map<String, List<String>> v, {
  bool not = false,
  String id = 'r1',
}) => _rule({'domain': _card(v, not: not)}, id: id);

void main() {
  group('domain exact (case-insensitive)', () {
    final r = _domain({
      'domain': ['example.com'],
    });
    for (final (host, want) in [
      ('example.com', true),
      ('EXAMPLE.com', true),
      ('www.example.com', false),
      ('example.org', false),
      ('exampl.com', false),
    ]) {
      test('$host → $want', () => expect(ruleCatches(r, host), want));
    }
  });

  group('suffix', () {
    final r = _domain({
      'domain_suffix': ['google.com'],
    });
    for (final (host, want) in [
      ('google.com', true),
      ('www.google.com', true),
      ('a.b.google.com', true),
      ('notgoogle.com', false),
      ('google.com.evil.example', false),
    ]) {
      test('$host → $want', () => expect(ruleCatches(r, host), want));
    }

    // The leading dot is tolerated and means the same suffix.
    final dotted = _domain({
      'domain_suffix': ['.google.com'],
    });
    for (final (host, want) in [
      ('google.com', true),
      ('www.google.com', true),
      ('notgoogle.com', false),
    ]) {
      test(
        '.google.com: $host → $want',
        () => expect(ruleCatches(dotted, host), want),
      );
    }
  });

  group('keyword (contains)', () {
    final r = _domain({
      'domain_keyword': ['google'],
    });
    for (final (host, want) in [
      ('www.google.com', true),
      ('googlevideo.example', true),
      ('example.com', false),
    ]) {
      test('$host → $want', () => expect(ruleCatches(r, host), want));
    }
  });

  group('regex', () {
    final r = _domain({
      'domain_regex': [r'^.+\.ru$'],
    });
    for (final (host, want) in [('shop.ru', true), ('shop.com', false)]) {
      test('$host → $want', () => expect(ruleCatches(r, host), want));
    }

    test('an invalid pattern never matches and does not throw', () {
      final bad = _domain({
        'domain_regex': ['(['],
      });
      expect(() => ruleCatches(bad, 'shop.ru'), returnsNormally);
      expect(ruleCatches(bad, 'shop.ru'), isFalse);
    });
  });

  group('IP-CIDR and IP range (IP host only)', () {
    final cidr = _rule({
      'ip': _card({
        'ip_cidr': ['10.0.0.0/8'],
      }),
    });
    for (final (host, want) in [
      ('10.1.2.3', true),
      ('10.255.255.255', true),
      ('11.0.0.1', false),
    ]) {
      test('CIDR $host → $want', () => expect(ruleCatches(cidr, host), want));
    }

    final range = _rule({
      'ip': _card({
        'ip_cidr': ['1.1.1.1-1.1.1.9'],
      }),
    });
    for (final (host, want) in [
      ('1.1.1.1', true),
      ('1.1.1.5', true),
      ('1.1.1.9', true),
      ('1.1.1.10', false),
      ('1.1.1.0', false),
    ]) {
      test('range $host → $want', () => expect(ruleCatches(range, host), want));
    }

    test('an IP rule never catches a name host, with or without not', () {
      expect(ruleCatches(cidr, 'example.com'), isFalse);
      expect(ruleCatches(range, 'example.com'), isFalse);
      final inverted = _rule({
        'ip': _card({
          'ip_cidr': ['10.0.0.0/8'],
        }, not: true),
      });
      expect(ruleCatches(inverted, 'example.com'), isFalse);
    });
  });

  group('ports and port ranges (port given)', () {
    final r = _rule({
      'port': _card({
        'port': ['443', '8000-9000'],
      }),
    });
    for (final (port, want) in [
      (443, true),
      (8000, true),
      (8500, true),
      (9000, true),
      (9001, false),
      (7999, false),
      (80, false),
    ]) {
      test(
        'port $port → $want',
        () => expect(ruleCatches(r, 'example.com', port: port), want),
      );
    }

    test('no port given → undecidable → false', () {
      expect(ruleCatches(r, 'example.com'), isFalse);
    });
  });

  group('domain AND port', () {
    final r = _rule({
      'domain': _card({
        'domain_suffix': ['example.com'],
      }),
      'port': _card({
        'port': ['443'],
      }),
    });
    test(
      'both match → true',
      () => expect(ruleCatches(r, 'www.example.com', port: 443), isTrue),
    );
    test(
      'port misses → false',
      () => expect(ruleCatches(r, 'www.example.com', port: 80), isFalse),
    );
    test(
      'domain misses → false',
      () => expect(ruleCatches(r, 'other.org', port: 443), isFalse),
    );
    test(
      'no port → false',
      () => expect(ruleCatches(r, 'www.example.com'), isFalse),
    );
  });

  group('not inverts a decidable group', () {
    final notGoogle = _domain({
      'domain_suffix': ['google.com'],
    }, not: true);
    test(
      'miss → true',
      () => expect(ruleCatches(notGoogle, 'example.com'), isTrue),
    );
    test(
      'hit → false',
      () => expect(ruleCatches(notGoogle, 'www.google.com'), isFalse),
    );

    final notPort = _rule({
      'port': _card({
        'port': ['443'],
      }, not: true),
    });
    test(
      'port 80 (not 443) → true',
      () => expect(ruleCatches(notPort, 'example.com', port: 80), isTrue),
    );
    test(
      'port 443 → false',
      () => expect(ruleCatches(notPort, 'example.com', port: 443), isFalse),
    );
  });

  group('OR over values and fields inside one group', () {
    final r = _rule({
      'domain': _card({
        'domain_suffix': ['google.com'],
        'domain': ['example.com'],
      }),
    });
    test(
      'suffix value matches',
      () => expect(ruleCatches(r, 'www.google.com'), isTrue),
    );
    test(
      'exact field matches',
      () => expect(ruleCatches(r, 'example.com'), isTrue),
    );
    test(
      'neither matches',
      () => expect(ruleCatches(r, 'example.org'), isFalse),
    );
  });

  group('two groups are ANDed', () {
    final r = _rule({
      'domain': _card({
        'domain_suffix': ['example.com'],
      }),
      'port': _card({
        'port': ['443'],
      }, not: true),
    });
    test(
      'both hold → true',
      () => expect(ruleCatches(r, 'www.example.com', port: 80), isTrue),
    );
    test(
      'first holds, second fails → false',
      () => expect(ruleCatches(r, 'www.example.com', port: 443), isFalse),
    );
    test(
      'second holds, first fails → false',
      () => expect(ruleCatches(r, 'other.org', port: 80), isFalse),
    );
  });

  group('undecidable groups → the whole rule is false', () {
    final cases = <(String, UserRule, String, int?)>[
      (
        'geosite',
        _domain({
          'geosite': ['youtube'],
        }),
        'example.com',
        null,
      ),
      (
        'geosite in the matching group',
        _rule({
          'domain': _card({
            'domain_suffix': ['example.com'],
            'geosite': ['youtube'],
          }),
        }),
        'example.com',
        null,
      ),
      (
        'geosite inverted',
        _rule({
          'domain': _card({
            'geosite': ['youtube'],
          }, not: true),
        }),
        'example.com',
        null,
      ),
      (
        'rule set',
        _rule({
          'domain': _card({
            'rule_set': ['ru-blocked'],
          }),
        }),
        'example.com',
        null,
      ),
      (
        'geoip on an IP host',
        _rule({
          'ip': _card({
            'geoip': ['ru'],
          }),
        }),
        '10.1.2.3',
        null,
      ),
      (
        'local networks flag on a name',
        _rule({'ip': _card({}, flag: true)}),
        'example.com',
        null,
      ),
      (
        'source address',
        _rule({
          'source': _card({
            'source_ip_cidr': ['192.168.1.0/24'],
          }),
        }),
        '192.168.1.5',
        null,
      ),
      (
        'source port',
        _rule({
          'source': _card({
            'source_port': ['5000-6000'],
          }),
        }),
        'example.com',
        5500,
      ),
      (
        'network',
        _rule({
          'network': _card({
            'network': ['tcp'],
          }),
        }),
        'example.com',
        443,
      ),
      (
        'protocol',
        _rule({
          'network': _card({
            'protocol': ['tls'],
          }),
        }),
        'example.com',
        443,
      ),
      (
        'process',
        _rule({
          'process': _card({
            'process': ['chrome.exe'],
          }),
        }),
        'example.com',
        null,
      ),
      (
        'domain match ANDed with a geosite group',
        _rule({
          'domain': _card({
            'domain_suffix': ['example.com'],
          }),
          'network': _card({
            'protocol': ['tls'],
          }),
        }),
        'www.example.com',
        443,
      ),
    ];
    for (final (label, r, host, port) in cases) {
      test(label, () => expect(ruleCatches(r, host, port: port), isFalse));
    }
  });

  group('composite and disabled rules → false', () {
    test('composite (raw JSON) never catches, even when the groups match', () {
      final r = _rule(
        {
          'domain': _card({
            'domain_suffix': ['example.com'],
          }),
        },
        composite: {'type': 'logical', 'mode': 'and', 'rules': <dynamic>[]},
      );
      expect(ruleCatches(r, 'www.example.com'), isFalse);
    });

    test('disabled rule never catches', () {
      final off = _rule({
        'domain': _card({
          'domain_suffix': ['example.com'],
        }),
      }, enabled: false);
      expect(ruleCatches(off, 'www.example.com'), isFalse);
    });

    test('the same rule enabled catches (control)', () {
      final on = _rule({
        'domain': _card({
          'domain_suffix': ['example.com'],
        }),
      });
      expect(ruleCatches(on, 'www.example.com'), isTrue);
    });
  });

  group('rulesCatching: own rules follow ruleOrder', () {
    late Catalog cat;
    setUp(() {
      cat = Catalog();
      // Inserted in one order, listed in another: the answer follows ruleOrder.
      cat.rulesData['a'] = _domain({
        'domain': ['example.com'],
      }, id: 'a');
      cat.rulesData['b'] = _rule({
        'domain': _card({
          'domain_suffix': ['example.com'],
        }),
      }, id: 'b');
      cat.rulesData['c'] = _domain({
        'domain_keyword': ['other'],
      }, id: 'c');
      cat.rulesData['d'] = _rule(
        {
          'domain': _card({
            'domain_suffix': ['example.com'],
          }),
        },
        id: 'd',
        enabled: false,
      );
      cat.rulesData['p'] = _rule({
        'port': _card({
          'port': ['443'],
        }),
      }, id: 'p');
      cat.ruleOrder = ['b', 'a', 'c', 'd', 'p'];
    });

    test('ids of the catching rules, in ruleOrder', () {
      expect(rulesCatching(cat, 'example.com'), ['b', 'a']);
    });

    test('a port rule is skipped without a port and included with one', () {
      expect(rulesCatching(cat, 'example.com'), isNot(contains('p')));
      expect(rulesCatching(cat, 'example.com', port: 443), ['b', 'a', 'p']);
    });

    test('no match → empty list', () {
      expect(rulesCatching(cat, 'nothing.test'), isEmpty);
    });
  });

  group('rulesCatching with app: that app\'s rules, in list order', () {
    late Catalog cat;
    setUp(() {
      cat = Catalog();
      cat.rulesData['own'] = _domain({
        'domain_suffix': ['example.com'],
      }, id: 'own');
      cat.ruleOrder = ['own'];
      cat.appRules['com.app'] = AppRule.fromJson({
        'rules': [
          {
            'id': 'ar3',
            'enabled': true,
            'action': 'proxy',
            'groups': {
              'domain': _card({
                'domain': ['example.com'],
              }),
            },
          },
          {
            'id': 'ar1',
            'enabled': true,
            'action': 'proxy',
            'groups': {
              'domain': _card({
                'domain_suffix': ['example.com'],
              }),
            },
          },
          {
            'id': 'ar2',
            'enabled': true,
            'action': 'proxy',
            'groups': {
              'domain': _card({
                'domain_keyword': ['other'],
              }),
            },
          },
          {
            'id': 'ar4',
            'enabled': false,
            'action': 'proxy',
            'groups': {
              'domain': _card({
                'domain_suffix': ['example.com'],
              }),
            },
          },
        ],
      });
    });

    test(
      'the app\'s catching rules in its list order, own rules not included',
      () {
        expect(rulesCatching(cat, 'example.com', app: 'com.app'), [
          'ar3',
          'ar1',
        ]);
      },
    );

    test('an app with no rules, or an unknown app → empty list', () {
      expect(rulesCatching(cat, 'example.com', app: 'com.missing'), isEmpty);
    });

    test('without app, the own list answers', () {
      expect(rulesCatching(cat, 'example.com'), ['own']);
    });
  });
}
