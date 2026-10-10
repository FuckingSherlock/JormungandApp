// Redactor: credentials and tokens leave the report, hosts / ports / names stay, the same value
// keeps one placeholder, and a second pass changes nothing.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

void main() {
  group('urls', () {
    test('a web URL keeps scheme and host, loses path and query', () {
      final r = Redactor();
      final s = r.text('GET https://sub.example.com:8443/api/v1/sub/AbCdEf123?token=zzz&x=1 failed: timeout');
      expect(s, startsWith('GET https://sub.example.com:8443/<url#1> failed'));
      expect(s, isNot(contains('AbCdEf123')));
      expect(r.counts['url'], 1);
    });

    test('userinfo of a web URL goes, the host stays', () {
      final s = Redactor().text('fetch https://admin:hunter2@panel.example.org/x');
      expect(s, contains('<userinfo#1>@panel.example.org/'));
      expect(s, isNot(contains('hunter2')));
    });

    test('a bare host URL and a root path are left alone', () {
      final s = Redactor().text('probe https://www.example.com/ and http://example.net:8080');
      expect(s, 'probe https://www.example.com/ and http://example.net:8080');
    });

    test('trailing punctuation stays outside the URL', () {
      final s = Redactor().text('see https://example.com/secret/path.');
      expect(s, 'see https://example.com/<url#1>.');
    });

    test('a vless link: the account and the key parameters go, the endpoint and the name stay', () {
      final r = Redactor();
      final s = r.text(
        'vless://$_uuid@node1.example.com:443?encryption=none&security=reality&sni=www.example.org'
        '&fp=chrome&pbk=PUBLICKEYabcdefghijklmnopqrstuvwxyz0123456789ABC&sid=ab12cd&type=tcp&flow=xtls-rprx-vision#My%20Node',
      );
      expect(s, isNot(contains(_uuid)));
      expect(s, isNot(contains('PUBLICKEY')));
      expect(s, isNot(contains('sid=ab12cd')));
      expect(s, contains('@node1.example.com:443?'));
      expect(s, contains('sni=www.example.org'));
      expect(s, contains('security=reality'));
      expect(s, contains('flow=xtls-rprx-vision'));
      expect(s, endsWith('#My%20Node'));
      expect(r.counts.keys, containsAll(['link', 'secret']));
    });

    test('a vmess link and a legacy ss link: the whole blob goes', () {
      final r = Redactor();
      final vm = r.text('vmess://eyJhZGQiOiJub2RlLmV4YW1wbGUuY29tIiwiaWQiOiIxMTExMTExMSJ9');
      expect(vm, matches(RegExp(r'^vmess://<link#\d+>$')));
      final ss = r.text('ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@ss.example.com:8388#name');
      expect(ss, 'ss://<link#2>@ss.example.com:8388#name');
    });
  });

  group('secrets in text', () {
    test('key=value and key: value forms', () {
      final r = Redactor();
      expect(r.text('connect password=hunter2 user=bob'), 'connect password=<secret#1> user=bob');
      expect(r.text('{"password": "hunter2", "port": 443}'), '{"password": "<secret#1>", "port": 443}');
      expect(r.text('token: abc12345def'), 'token: <secret#2>');
      expect(r.text('api_key=AAAA1111 client_secret=BBBB2222'), 'api_key=<secret#3> client_secret=<secret#4>');
    });

    test('a word is not a secret: prose with key / pass / token stays', () {
      const s = 'the key point: pass the token to the next hop and key lookup failed';
      expect(Redactor().text(s), s);
    });

    test('Bearer tokens', () {
      final r = Redactor();
      expect(r.text('Authorization: Bearer abcDEF123456.xyz'), 'Authorization: Bearer <token#1>');
      expect(r.text('header Bearer abcDEF123456.xyz again'), 'header Bearer <token#1> again');
    });

    test('UUIDs anywhere, stable numbering', () {
      final r = Redactor();
      expect(r.text('user $_uuid and again $_uuid'), 'user <uuid#1> and again <uuid#1>');
      expect(r.text('other 99999999-8888-7777-6666-555555555555'), 'other <uuid#2>');
      expect(r.counts['uuid'], 3);
    });

    test('long random strings are tokens in free text, not in fixed fields; file digests stay', () {
      const tok = 'AbCd1234EfGh5678IjKl9012MnOp3456QrSt7890';
      const sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final r = Redactor();
      expect(r.text('session $tok ok'), 'session <token#1> ok');
      expect(r.text('sha256 $sha ok'), 'sha256 $sha ok');
      expect(Redactor().text('commit $tok', free: false), 'commit $tok');
      // a long word without digits is a word
      expect(r.text('Pneumonoultramicroscopicsilicovolcanoconiosis_is_a_long_word_indeed'), startsWith('Pneumono'));
    });

    test('Telegram bot tokens', () {
      final s = Redactor().text('bot 123456789:AAFa1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6 sent');
      expect(s, 'bot <token#1> sent');
    });

    test('hosts, IPs, ports, packages and ordinary lines are untouched', () {
      const lines = [
        '[123 5ms] inbound/tun[tun-in]: inbound connection from 10.0.0.2:51234',
        '[124 0ms] router: found package name: org.telegram.messenger',
        '[125 12ms] outbound/vless[route0/n1a2b3c4d5e6f]: outbound connection to api.example.com:443',
        'dns: exchange failed for example.com. IN A: context deadline exceeded',
        '2001:db8::1 -> 192.168.1.5:8080 via eth0',
      ];
      for (final l in lines) {
        expect(Redactor().text(l), l);
      }
    });
  });

  group('structures', () {
    test('values of secret-named keys are replaced whole, nested too', () {
      final r = Redactor();
      final out = r.json({
        'name': 'Node',
        'outbound': {'type': 'vless', 'server': 'node1.example.com', 'uuid': _uuid, 'password': 'p', 'tls': {'reality': {'public_key': 'KKK', 'short_id': 'ab'}}},
        'list': [
          {'token': 'abc'},
          'plain',
        ],
      }) as Map;
      final o = out['outbound'] as Map;
      expect(o['server'], 'node1.example.com');
      expect(o['uuid'], matches(RegExp(r'^<secret#\d+>$')));
      expect(o['password'], matches(RegExp(r'^<secret#\d+>$')));
      expect(((out['list'] as List).first as Map)['token'], matches(RegExp(r'^<secret#\d+>$')));
      expect(out['name'], 'Node');
      expect(r.total, greaterThanOrEqualTo(3));
    });

    test('a second pass changes nothing and counts nothing', () {
      final first = Redactor();
      final src = {
        'msg': 'vless://$_uuid@h.example.com:443?pbk=ABCDEFGH&sid=1234#n Bearer abcDEF123456 password=hunter2 https://u:p@h.example.com/x/y?z=1',
      };
      final once = first.json(src);
      final second = Redactor();
      expect(second.json(once), once);
      expect(second.total, 0);
    });

    test('numbers and booleans pass through; counts add up', () {
      final r = Redactor();
      expect(r.json({'n': 1, 'ok': true, 'none': null, 'port': 443}), {'n': 1, 'ok': true, 'none': null, 'port': 443});
      r.text('password=a password=b password=a');
      expect(r.counts['secret'], 3);
      expect(r.total, 3);
    });
  });
}
