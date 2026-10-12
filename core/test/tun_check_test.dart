// The active TUN test (tun_check.dart): the responder, and how the three failure reasons come out.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

void main() {
  late TunCheck check;
  late Future<Socket> Function(String, int, Duration) dial;

  Future<TunCheck> make() => TunCheck.bind(
        connect: (h, p, t) => dial(h, p, t),
        connectTimeout: const Duration(milliseconds: 300),
        answerTimeout: const Duration(milliseconds: 300),
      );

  tearDown(() => check.close());

  test('the token reaches the responder: pass; the test aims at the documentation address', () async {
    final aimed = <String>[];
    check = await make();
    dial = (h, p, t) {
      aimed.add('$h:$p');
      return Socket.connect('127.0.0.1', check.port); // a TUN that works
    };
    final r = await check.run(Cancel());
    expect(r.outcome, Outcome.pass);
    expect(r.code, tunCheckCode);
    expect(aimed, ['$tunCheckAddress:$tunCheckPort']);
  });

  test('refused: the connect fails at once', () async {
    check = await make();
    dial = (h, p, t) async => throw const SocketException('unreachable');
    final r = await check.run(Cancel());
    expect([r.outcome, r.params['reason']], [Outcome.fail, 'refused']);
  });

  test('silent: the connect is not answered in time', () async {
    check = await make();
    dial = (h, p, t) async => throw TimeoutException('no answer');
    final r = await check.run(Cancel());
    expect([r.outcome, r.params['reason']], [Outcome.fail, 'silent']);
  });

  test('unrouted: the stack accepts the connection, the token never arrives', () async {
    check = await make();
    final sink = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0); // accepts, reads nothing on
    sink.listen((_) {});
    addTearDown(sink.close);
    dial = (h, p, t) => Socket.connect('127.0.0.1', sink.port);
    final r = await check.run(Cancel());
    expect([r.outcome, r.params['reason']], [Outcome.fail, 'unrouted']);
  });
}
