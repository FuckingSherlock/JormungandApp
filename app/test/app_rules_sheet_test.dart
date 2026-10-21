import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/pages/rules_page.dart';
import 'package:jormungand/widgets/apps_sheet.dart';
import 'package:jormungand/widgets/chip_input.dart';
import 'package:jormungand/widgets/rule_form.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

// Android: the app-rule rules of docs/rules.md §3 and the "no app condition" rule of §4 are Android rules.
const _tg = 'org.telegram.messenger';
const _chrome = 'com.android.chrome';
const _tgApp = InstalledApp(pkg: _tg, name: 'Telegram');
const _chromeApp = InstalledApp(pkg: _chrome, name: 'Chrome');

const _names = ['alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf'];

FakeCoreHost _host() => FakeCoreHost(android: true);

UserRule _rule(String id, String name) =>
    UserRule(id: id, name: name, enabled: true, action: 'direct');

/// Own rules named `Own <name>` in [_names] order; the first four are the rows shown before "N more".
void _ownRules(FakeCoreHost host, int n) {
  for (var i = 0; i < n; i++) {
    host.catalog.rulesData['r$i'] = _rule('r$i', 'Own ${_names[i]}');
  }
  host.catalog.ruleOrder = [for (var i = 0; i < n; i++) 'r$i'];
}

/// The app [pkg] with [n] rules named `App <name>`.
void _appRules(FakeCoreHost host, String pkg, int n) {
  host.catalog.appRules[pkg] = AppRule(
    rules: [for (var i = 0; i < n; i++) _rule('ar$i', 'App ${_names[i]}')],
  );
}

/// Tall enough that the rule lists are built in full (a lazy list builds only the rows near the screen).
void _tall(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(800, 3000);
}

Finder _moreRow() => find.byWidgetPredicate(
  (w) => w is Text && RegExp(r'^\d+ more$').hasMatch(w.data ?? ''),
);

/// The text field of the first condition card: a new form starts with one empty "Suffix" field (§4).
Finder _suffixField() =>
    find.descendant(of: find.byType(ChipInput).first, matching: find.byType(TextField));

/// The section label is shown upper-cased (RulesLabel), so match it ignoring case.
Finder _appRulesLabel() => find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').toLowerCase() == 'rules in this app',
);

/// The Save button of the form on top; an app sheet under it has its own Save.
Finder _saveButton() => find.text('Save').hitTestable();

Finder _addRuleButton() => find.byWidgetPredicate(
  (w) => w is Text && (w.data == '+ Rule' || w.data == 'New rule'),
);

Finder _anyContext() => find.byType(Scaffold).first;

Future<void> _typeSuffix(WidgetTester tester, String value) async {
  await tester.enterText(_suffixField(), value);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

CatalogNode _node(String id, String name) => CatalogNode(
  id: id,
  name: name,
  flag: '\u{1F1E9}\u{1F1EA}',
  protocol: 'vless',
  address: '$id.example.com',
  port: 443,
);

void main() {
  group('the shared rule list (Rules sheet, own rules)', () {
    // (rules, what the list shows under the first four rows)
    for (final c in const [(4, null), (5, '1 more'), (7, '3 more')]) {
      testWidgets(
        '${c.$1} rules: the first four rows, ${c.$2 == null ? 'no "more" row' : 'then "${c.$2}"'}',
        (tester) async {
          final host = _host();
          _ownRules(host, c.$1);
          await pumpApp(tester, host);
          _tall(tester);
          showRulesPage(tester.element(_anyContext()));
          await tester.pumpAndSettle();

          for (var i = 0; i < c.$1; i++) {
            expect(
              find.text('Own ${_names[i]}'),
              i < 4 ? findsOneWidget : findsNothing,
              reason: 'row ${i + 1}',
            );
          }
          expect(_moreRow(), c.$2 == null ? findsNothing : findsOneWidget);
          if (c.$2 != null) expect(find.text(c.$2!), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('tapping "3 more" shows every rule and drops the row', (tester) async {
      final host = _host();
      _ownRules(host, 7);
      await pumpApp(tester, host);
      _tall(tester);
      showRulesPage(tester.element(_anyContext()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('3 more'));
      await tester.pumpAndSettle();

      for (final n in _names) {
        expect(find.text('Own $n'), findsOneWidget);
      }
      expect(_moreRow(), findsNothing);
    });

    testWidgets('a search shows a rule that sits behind "N more"', (tester) async {
      final host = _host();
      _ownRules(host, 7);
      await pumpApp(tester, host);
      _tall(tester);
      showRulesPage(tester.element(_anyContext()));
      await tester.pumpAndSettle();
      expect(find.text('Own golf'), findsNothing); // the seventh rule is folded

      await tester.enterText(find.byType(TextField).first, 'golf');
      await tester.pumpAndSettle();

      expect(find.text('Own golf'), findsOneWidget);
    });
  });

  group('the app sheet (its own rules)', () {
    testWidgets('shows "Rules in this app" with that app\'s rules only, in check order', (tester) async {
      final host = _host()..apps = [_tgApp];
      host.catalog.appRules[_tg] = AppRule(
        rules: [_rule('a', 'App golf'), _rule('b', 'App alpha'), _rule('c', 'App delta')],
      );
      _ownRules(host, 1);
      await pumpApp(tester, host);
      _tall(tester);
      showAppAct(tester.element(_anyContext()), _tg, name: 'Telegram');
      await tester.pumpAndSettle();

      expect(_appRulesLabel(), findsOneWidget);
      expect(find.text('App golf'), findsOneWidget);
      expect(find.text('App alpha'), findsOneWidget);
      expect(find.text('App delta'), findsOneWidget);
      expect(find.text('Own alpha'), findsNothing); // the Rules sheet's list, not this one

      final top = [for (final n in ['App golf', 'App alpha', 'App delta']) tester.getTopLeft(find.text(n)).dy];
      expect(top[0] < top[1] && top[1] < top[2], isTrue, reason: 'top to bottom = check order');
    });

    for (final c in const [(4, null), (6, '2 more')]) {
      testWidgets(
        'app with ${c.$1} rules: the first four rows, ${c.$2 == null ? 'no "more" row' : 'then "${c.$2}", tap shows all'}',
        (tester) async {
          final host = _host()..apps = [_tgApp];
          _appRules(host, _tg, c.$1);
          await pumpApp(tester, host);
          _tall(tester);
          showAppAct(tester.element(_anyContext()), _tg, name: 'Telegram');
          await tester.pumpAndSettle();

          for (var i = 0; i < c.$1; i++) {
            expect(
              find.text('App ${_names[i]}'),
              i < 4 ? findsOneWidget : findsNothing,
              reason: 'row ${i + 1}',
            );
          }
          expect(_moreRow(), c.$2 == null ? findsNothing : findsOneWidget);
          if (c.$2 != null) {
            await tester.tap(find.text(c.$2!));
            await tester.pumpAndSettle();
            for (var i = 0; i < c.$1; i++) {
              expect(find.text('App ${_names[i]}'), findsOneWidget, reason: 'row ${i + 1}');
            }
            expect(_moreRow(), findsNothing);
          }
        },
      );
    }

    testWidgets('the add button opens the rule form for that app: no Process card', (tester) async {
      final host = _host()..apps = [_tgApp];
      await pumpApp(tester, host);
      _tall(tester);
      showAppAct(tester.element(_anyContext()), _tg, name: 'Telegram');
      await tester.pumpAndSettle();

      expect(_addRuleButton(), findsOneWidget);
      await tester.tap(_addRuleButton());
      await tester.pumpAndSettle();

      expect(_saveButton(), findsOneWidget);
      expect(find.text('Process'), findsNothing);
      expect(_suffixField(), findsOneWidget);
    });

    testWidgets('an app on Default with no rules is "default"; its first rule makes it "own" (the service note of Telegram says so)', (tester) async {
      final host = _host()..apps = [_tgApp];
      await pumpApp(tester, host);
      _tall(tester);
      showAppAct(tester.element(_anyContext()), _tg, name: 'Telegram');
      await tester.pumpAndSettle();

      // Telegram is a service app (serviceOfApp): a default app's note points at Rules → Services
      expect(find.textContaining('add it in Rules'), findsOneWidget);
      expect(find.textContaining('own route wins'), findsNothing);

      await tester.tap(_addRuleButton());
      await tester.pumpAndSettle();
      await _typeSuffix(tester, 'chat.example');
      await tester.tap(_saveButton());
      await tester.pumpAndSettle();

      expect(host.catalog.appRules[_tg]!.rules, hasLength(1));
      expect(find.textContaining('own route wins'), findsOneWidget);
      expect(find.textContaining('add it in Rules'), findsNothing);
    });
  });

  group('the rule form', () {
    testWidgets('on Android an own rule has no Process card either', (tester) async {
      final host = _host();
      await pumpApp(tester, host);
      _tall(tester);
      showRuleForm(tester.element(_anyContext()));
      await tester.pumpAndSettle();

      expect(find.text('Process'), findsNothing);
      expect(_suffixField(), findsOneWidget);
    });

    testWidgets(
      'appRuleOf: Save adds the rule to that app, not to own rules; reopened with its id it edits in place',
      (tester) async {
        final host = _host()..apps = [_tgApp];
        await pumpApp(tester, host);
        _tall(tester);

        showRuleForm(tester.element(_anyContext()), appRuleOf: _tg);
        await tester.pumpAndSettle();
        expect(find.text('Process'), findsNothing);
        await _typeSuffix(tester, 'chat.example');
        await tester.tap(_saveButton());
        await tester.pumpAndSettle();

        expect(host.catalog.rulesData, isEmpty, reason: 'it is not an own rule');
        final rules = host.catalog.appRules[_tg]!.rules;
        expect(rules, hasLength(1));
        expect(rules.single.toJson().toString(), contains('chat.example'));
        final id = rules.single.id;

        showRuleForm(tester.element(_anyContext()), id: id, appRuleOf: _tg);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Direct').first);
        await tester.pumpAndSettle();
        await tester.tap(_saveButton());
        await tester.pumpAndSettle();

        final after = host.catalog.appRules[_tg]!.rules;
        expect(after, hasLength(1));
        expect(after.single.id, id);
        expect(after.single.action, 'direct');
      },
    );

    testWidgets('a new rule for an app with no rules is "Rule №1", whatever other apps have', (tester) async {
      final host = _host()..apps = [_tgApp, _chromeApp];
      _appRules(host, _tg, 3);
      await pumpApp(tester, host);
      _tall(tester);

      showRuleForm(tester.element(_anyContext()), appRuleOf: _chrome);
      await tester.pumpAndSettle();
      await _typeSuffix(tester, 'chat.example');
      await tester.tap(_saveButton());
      await tester.pumpAndSettle();

      // the number is per app: the saved rule is "Rule #1" in its form title, whatever other apps have
      final saved = host.catalog.appRules[_chrome]!.rules.single;
      expect(host.catalog.appRules[_tg]!.rules, hasLength(3));
      showRuleForm(tester.element(_anyContext()), id: saved.id, appRuleOf: _chrome);
      await tester.pumpAndSettle();
      expect(find.text('Rule #1'), findsOneWidget);
    });
    for (final app in const [null, _tg]) {
      testWidgets(
        'fallbackVia prefills Action Proxy through the main flow and Fallback Proxy through the target (${app == null ? 'own rule' : 'app rule'})',
        (tester) async {
          final host = _host()..apps = [_tgApp];
          host.catalog.sourcesData['s1'] = Source(
            id: 's1',
            name: 'Alpha',
            url: 'https://alpha.example.com/sub',
            nodes: [_node('n1', 'Live one')],
          );
          host.catalog.sourceOrder = ['s1'];
          host.catalog.syncCatalog();
          await pumpApp(tester, host);
          _tall(tester);

          showRuleForm(
            tester.element(_anyContext()),
            host: 'chat.example',
            fallbackVia: 'src:s1',
            appRuleOf: app,
          );
          await tester.pumpAndSettle();
          await tester.tap(_saveButton());
          await tester.pumpAndSettle();

          final r = app == null
              ? host.catalog.rulesData.values.single
              : host.catalog.appRules[app]!.rules.single;
          expect(r.action, 'proxy');
          expect(r.target, isEmpty, reason: 'Via empty = the main flow');
          // stored Fallback Proxy is 'main' (docs/rules.md: fallback default|main|direct|block, main = Proxy)
          expect(r.fallback, 'main');
          expect(r.fallbackTarget, 'src:s1');
        },
      );
    }

    testWidgets('a rule started from a host is titled "New rule for <host>"', (tester) async {
      final host = _host();
      await pumpApp(tester, host);
      _tall(tester);

      showRuleForm(tester.element(_anyContext()), host: 'youtube.com');
      await tester.pumpAndSettle();

      expect(find.text('New rule for youtube.com'), findsOneWidget);
    });
  });
}
