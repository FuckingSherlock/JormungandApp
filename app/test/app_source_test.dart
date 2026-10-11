// Which app a request came from (display only): the app's icon and name on site events (the «why» rows),
// in the live connections sheet and on sing-box's «found package name» line of the raw log; a tap on the
// app opens its route (the per-app dialog of Rules → Apps); an unknown package shows its id, the system
// package «Android System».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/live_conns_sheet.dart';
import 'package:jormungand/widgets/rules_parts.dart' show AppIcon;
import 'package:jormungand_core/jormungand_core.dart' show LiveConn;

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

const _gone = {'entry': 'x', 'tried': <Object>[]};
const _tg = 'org.telegram.messenger';

FakeCoreHost _host() {
  final host = FakeCoreHost()..apps = const [InstalledApp(pkg: _tg, name: 'Telegram')];
  host.catalog.appInfo = (p) => p == _tg ? (name: 'Telegram', kind: 'package') : null;
  return host;
}

void main() {
  testWidgets('site events name the app with its icon; the package id when unknown; Android System; a tap opens its route', (tester) async {
    final host = _host();
    host.addEvent('site', 'unreachable', level: 'warn', data: {..._gone, 'host': 'a.example', 'app': _tg});
    host.addEvent('site', 'blocked', level: 'warn', data: {'host': 'b.example', 'entry': 'x', 'via': 'y', 'app': 'com.unknown.app'});
    host.addEvent('site', 'unreachable', level: 'warn', data: {..._gone, 'host': 'c.example', 'app': 'android'});
    host.addEvent('site', 'unreachable', level: 'warn', data: {..._gone, 'host': 'd.example'});
    await pumpApp(tester, host, width: 560); // the test font (Ahem) is wide: the dialog needs room
    tester.view.physicalSize = const Size(1120, 4000); // the list builds only what is in view: all four rows
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();

    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('com.unknown.app'), findsOneWidget, reason: 'not in the installed list: the package id');
    expect(find.text('Android System'), findsOneWidget);
    expect(find.byKey(const ValueKey('whyIcon:$_tg')), findsOneWidget, reason: 'the icon of the app, a letter tile without one');
    expect(find.byKey(const ValueKey('whyIcon:android')), findsOneWidget);
    expect(find.byType(AppIcon), findsNWidgets(3), reason: 'only the rows with an app carry an icon (d.example has none)');

    await tester.tap(find.text('Telegram'));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget, reason: 'the per-app dialog is open');
    expect(find.text('Telegram'), findsNWidgets(2), reason: 'its title is the app name');
  });

  testWidgets('Raw: sing-box\'s «found package name» line gets the app\'s icon and name after it; a tap opens its route', (tester) async {
    final host = _host();
    host.addLogLine('[4 1ms] router: found package name: $_tg');
    await pumpApp(tester, host, width: 560);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();
    expect(find.byType(AppIcon), findsNothing, reason: 'the line is connection flood: behind the «Connections» switch');
    expect(find.text('Connections hidden (1)'), findsOneWidget, reason: 'the status line says what the core left out');
    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rawConns')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5)); // closes the filter sheet
    await tester.pumpAndSettle();
    expect(find.text('Connections hidden (1)'), findsNothing);
    expect(find.byType(AppIcon), findsOneWidget);
    expect(find.text('Telegram'), findsOneWidget);
    await tester.tap(find.text('Telegram'));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('the live connections sheet shows the app of a connection (icon, name) and a tap opens its route', (tester) async {
    final host = _host();
    await pumpApp(tester, host, width: 560);
    host.setPhase(ConnectionPhase.connected);
    host.setTraffic(
      TrafficInfo(
        down: 0,
        up: 0,
        downTotal: 0,
        upTotal: 0,
        tcp: 1,
        udp: 0,
        conns: [
          LiveConn.fromJson({'id': '1', 'host': 'a.example', 'port': '443', 'net': 'tcp', 'out': const ['direct'], 'process': '', 'pkg': _tg, 'start': '2026-01-01T10:00:00Z'}),
          LiveConn.fromJson({'id': '2', 'host': 'b.example', 'port': '443', 'net': 'tcp', 'out': const ['direct'], 'process': '', 'pkg': 'android', 'start': '2026-01-01T10:00:00Z'}),
        ],
      ),
    );
    await tester.pumpAndSettle();
    unawaited(showLiveConnections(tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('connApp:1')), findsOneWidget);
    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('Android System'), findsOneWidget);

    await tester.tap(find.text('Telegram'));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget, reason: 'the sheet gave way to the per-app dialog');
  });

  testWidgets('the live connections sheet titles an app group with the app name and icon, the package id only when unknown, and picks the list up when it arrives', (tester) async {
    final host = FakeCoreHost(); // the installed list not read yet: no name for Telegram
    await pumpApp(tester, host, width: 560);
    host.setPhase(ConnectionPhase.connected);
    host.setTraffic(
      TrafficInfo(
        down: 0,
        up: 0,
        downTotal: 0,
        upTotal: 0,
        tcp: 2,
        udp: 0,
        conns: [
          // bare IPs: the group is the app's
          LiveConn.fromJson({'id': '1', 'host': '1.2.3.4', 'port': '443', 'net': 'tcp', 'out': const ['direct'], 'process': '', 'pkg': _tg, 'start': '2026-01-01T10:00:00Z'}),
          LiveConn.fromJson({'id': '2', 'host': '1.2.3.5', 'port': '443', 'net': 'tcp', 'out': const ['direct'], 'process': '', 'pkg': 'com.unknown.app', 'start': '2026-01-01T10:00:00Z'}),
        ],
      ),
    );
    await tester.pumpAndSettle();
    unawaited(showLiveConnections(tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();

    expect(find.text(_tg), findsNWidgets(2), reason: 'group title and row: the list is not here yet');

    host.catalog.appInfo = (p) => p == _tg ? (name: 'Telegram', kind: 'package') : null;
    host.changed(); // the list arrived
    await tester.pumpAndSettle();
    expect(find.text('Telegram'), findsNWidgets(2), reason: 'the group title and the row name the app');
    expect(find.text(_tg), findsNothing, reason: 'no package id left for a known app');
    expect(find.text('com.unknown.app'), findsNWidgets(2), reason: 'unknown package: its id');
    expect(find.byKey(const ValueKey('groupIcon:$_tg')), findsOneWidget);
    expect(find.byKey(const ValueKey('groupIcon:com.unknown.app')), findsOneWidget);
  });
}
