// The English strings of the dns-site-events stage (docs/logs.md «DNS-события», docs/connect-model.md «Карточка сайта»):
// the new l10n texts as the generated AppLocalizations renders them, the ICU plural of the site line, and the type
// labels of dns/down, dns/up, dns/transport (and the fallback of the removed dns/failed*).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';

import 'fake_core_host.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('new English strings', () {
    test('the texts without a placeholder read as the plan says (reused keys included)', () {
      expect(
        [
          en.dnsSwitched,
          en.dnsDoesNotAnswer, // dnsNoAnswerTitle and typeDnsDown
          en.noAnswer, // reused: the text exists already
          en.vpn, // reused: sideVpn
          en.direct3, // reused: sideDirect
          en.noAnswerStaysSelected,
          en.noAnswerNoSpareDnsOn,
          en.checkedThrough,
          en.throughVpn,
          en.answersSpareNode,
          en.dnsSettings,
          en.networkEvent,
          en.details,
          en.dnsTransportChanges,
          en.everywhere,
          en.onThisRouteOnly,
          en.ignoredSites2,
          en.theSiteOpensThroughAnotherServer,
        ],
        [
          'DNS switched',
          'DNS does not answer',
          'no answer',
          'VPN',
          'Direct',
          'no answer · stays selected',
          'no answer · no spare DNS on this side',
          'Checked through',
          'Through VPN',
          'answers — spare node',
          'DNS settings',
          'Network event',
          'Details ▾',
          'DNS transport changes',
          'Everywhere',
          'On this route only',
          'Ignored sites…',
          'the site opens through another server',
        ],
      );
    });

    test('the texts with a placeholder take the value into the sentence', () {
      expect(en.changedTransport('Alpha'), 'Alpha changed transport');
      expect(en.dnsAnswersAgainAfter('5 s'), 'DNS answers again — after 5 s');
      expect(en.noAnswerForS(5), 'no answer for 5 s');
      expect(en.itself('Alpha'), 'Alpha itself');
      expect(en.answersThroughTheSameRoute('Beta'), 'Beta answers through the same route');
      expect(en.doesNotAnswerOnThisRoute('Alpha'), 'Alpha does not answer on this route');
      expect(en.ofTheSameServerDoes('Beta'), 'Beta of the same server does');
      expect(en.node('k1'), 'node k1');
      expect(en.answersThroughAnotherNode('Alpha'), 'Alpha answers through another node');
      expect(en.fallback2('Rule A'), 'Fallback: Rule A');
      expect(en.opensInMs(120), 'opens in 120 ms');
      expect(en.didNotOpenOnOfServers('example.org', 2, 4), 'example.org did not open on 2 of 4 servers');
    });

    test('siteDidNotOpenN is a plural: "server" for one, "servers" for three', () {
      expect(en.didNotOpenOnServersPlural(1, 'example.org'), 'example.org did not open on 1 server');
      expect(en.didNotOpenOnServersPlural(3, 'example.org'), 'example.org did not open on 3 servers');
    });
  });

  group('type labels', () {
    test('dns/down, dns/transport have their words; dns/up has its own label, not the raw type', () {
      final words = EventWords(en, FakeCoreHost().catalog);
      expect(words.typeLabel('dns', 'down'), 'DNS does not answer');
      expect(words.typeLabel('dns', 'transport'), 'DNS transport changes');
      final up = words.typeLabel('dns', 'up');
      expect(up, isNotEmpty);
      expect(up, isNot('dns/up'));
      expect(up, isNot(contains('/')));
    });

    test('dns/failed and dns/failedOnNode lost their texts: the old journal rows fall back, no crash', () {
      final words = EventWords(en, FakeCoreHost().catalog);
      for (final type in ['failed', 'failedOnNode']) {
        expect(() => words.typeLabel('dns', type), returnsNormally, reason: type);
        expect(words.typeLabel('dns', type), isNotEmpty, reason: type);
      }
    });
  });
}
