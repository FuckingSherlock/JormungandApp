// Screenshots of how the app shows events today (toast, system notification, row and card in
// Logs -> Events, other surfaces), for the events UI redesign. Not part of the normal suite:
//   flutter test test/_shots/event_shots_test.dart --run-skipped
// (dart_test.yaml skips the `shots` tag). PNGs and README.md go to app/build/event_shots/.
// Captions are Russian, test-only Text; nothing here touches app strings.
@Tags(['shots'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/core/app_update.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/core/system_notifier.dart';
import 'package:jormungand/core/update_flow.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/shell/app_links.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/event_rows.dart';
import 'package:jormungand/widgets/source_error_strip.dart';
import 'package:jormungand/widgets/vpn_alert.dart';
import 'package:jormungand_core/jormungand_core.dart';

import '../fake_core_host.dart';
import '../system_notification_test.dart' show FakeNotifyIo;

const _w = 400.0; // phone width, logical px
const _ratio = 2.0;
const _maxPage = 3000; // physical px
final _out = Directory('build/event_shots');
final _en = lookupAppLocalizations(const Locale('en'));
final _now = DateTime.now().millisecondsSinceEpoch;

Future<ByteData> _bytes(String p) async => ByteData.sublistView(Uint8List.fromList(await File(p).readAsBytes()));

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? 'G:/ANDROID_DEV/flutter';
  final d = '$root/bin/cache/artifacts/material_fonts';
  await (FontLoader('Roboto')
        ..addFont(_bytes('$d/roboto-regular.ttf'))
        ..addFont(_bytes('$d/roboto-medium.ttf'))
        ..addFont(_bytes('$d/roboto-bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(_bytes('$d/materialicons-regular.otf'))).load();
  // the theme's fallback family: the app bundles the flag font there
  // only flags: Windows has no flag glyphs of its own
  final fl = FontLoader('Flags')..addFont(_bytes('assets/fonts/TwemojiCountryFlags.ttf'));
  await fl.load();
  // Android draws ⚠️ ✅ → with its system fonts; this Windows machine's Segoe ones stand in for them, named
  // after the flags in the harness theme's fallback (_Shell), so no app code is touched.
  for (final (fam, f) in [('SegoeSym', 'seguisym.ttf'), ('SegoeEmoji', 'seguiemj.ttf')]) {
    if (File('C:/Windows/Fonts/$f').existsSync()) await (FontLoader(fam)..addFont(_bytes('C:/Windows/Fonts/$f'))).load();
  }
}

// ───────────────────────────── the fake data ─────────────────────────────

CatalogNode _node(String id, String name, String proto) =>
    CatalogNode(id: id, name: name, flag: '\u{1F1E9}\u{1F1EA}', protocol: proto, address: '$id.example.com', port: 443);

FakeCoreHost _host() {
  final h = FakeCoreHost();
  h.catalog.sourcesData['s1'] = Source(id: 's1', name: 'Remnawave', url: 'https://sub.example.com/a', nodes: [
    _node('n1', 'Frankfurt 1', 'vless'),
    _node('n2', 'Amsterdam 2', 'vless'),
    _node('n3', 'Helsinki 1', 'hysteria2'),
  ]);
  h.catalog.sourcesData['s2'] = Source(id: 's2', name: 'Backup VPN', url: 'https://sub.example.com/b', nodes: [_node('b1', 'Warsaw', 'trojan')]);
  h.catalog.sourceOrder = ['s1', 's2'];
  h.catalog.chainsData['c1'] = Chain(id: 'c1', name: 'Remnawave via Backup', inId: 's1', outId: 's2');
  h.catalog.catalogOrder['simple'] = ['s1', 's2', 'c1'];
  h.catalog.rulesData['r1'] = UserRule(id: 'r1', name: 'Streaming', enabled: true, action: 'proxy', target: 'src:s2', fallback: 'block');
  h.catalog.ruleOrder = ['r1'];
  h.catalog.syncCatalog();
  for (final k in notifDefaults.keys) {
    h.notif.setFlag(k, true); // every switch on, so that each kind that can notify is seen notifying
  }
  return h;
}

/// One event with its caption data. [id] is set when the record is made.
class Ev {
  const Ev(this.cat, this.type, this.data, {this.level = 'warn', this.bg = false, this.log, this.variant = ''});
  final String cat, type, level, variant;
  final Map<String, dynamic> data;
  final bool bg;
  final int? log;
  String get key => '$cat/$type';
}

const _chk = [
  {'cc': 'DE', 'country': 'Germany', 'city': 'Frankfurt', 'ok': true, 'code': 200, 'ms': 210},
  {'cc': 'FR', 'country': 'France', 'ok': false, 'error': 'Connection timed out'},
];
Map<String, dynamic> _unreach({Map<String, dynamic>? check, List<Map<String, String>>? tried, bool off = false, Map<String, dynamic>? more}) => {
  'host': 'dead.example.com',
  'port': 443,
  'entry': 'c1',
  'server': 's1::n1',
  'dest': 'dead.example.com:443',
  'tried': tried ?? const [],
  if (off) 'retries': 'off',
  'rule': {'kind': 'user', 'id': 'r1', 'name': 'Streaming'},
  'app': 'org.mozilla.firefox',
  'check': ?check,
  ...?more,
};

final _events = <String, List<Ev>>{
  'site': [
    Ev('site', 'unreachable', _unreach(check: {'state': 'opens', 'at': _now, 'ok': 2, 'total': 2, 'via': 'tunnel', 'nodes': _chk}, tried: [{'entry': 's2', 'server': 's2::b1'}]), log: 1204, variant: 'чекер: открывается из других стран (единственный вариант, который уведомляет)'),
    Ev('site', 'unreachable', _unreach(), variant: 'чекер ещё не спрашивали (нет других маршрутов)'),
    Ev('site', 'unreachable', _unreach(check: {'state': 'pending', 'at': _now}, tried: [{'entry': 's2', 'server': 's2::b1'}]), variant: 'чекер сейчас отвечает (pending)'),
    Ev('site', 'unreachable', _unreach(check: {'state': 'down', 'at': _now, 'ok': 0, 'total': 2, 'nodes': _chk}), variant: 'чекер: не открывается нигде (down everywhere)'),
    Ev('site', 'unreachable', _unreach(check: {'state': 'failed', 'at': _now, 'error': 'timeout'}, off: true), variant: 'повторы по другим маршрутам выключены, чекер не ответил'),
    Ev('site', 'unreachable', _unreach(more: {'repeat': {'count': 4, 'at': [_now - 400000, _now - 300000, _now - 200000, _now - 100000]}}), bg: true, variant: 'повтор x4, найден при погашенном экране (bg)'),
    Ev('site', 'blocked', {'host': 'video.example.net', 'port': 443, 'entry': 's1', 'server': 's1::n1', 'dest': 'video.example.net:443', 'via': 's2', 'viaServer': 's2::b1', 'rule': {'kind': 'service', 'id': 'youtube', 'name': 'YouTube'}, 'app': 'com.google.android.youtube'}, log: 1190, variant: 'открывается через другую запись (есть via)'),
    Ev('site', 'blocked', {'host': 'video.example.net', 'port': 443, 'entry': 's1', 'server': 's1::n1', 'dest': 'video.example.net:443', 'via': 's1', 'viaServer': 's1::n2', 'viaTarget': 'node:s1::n2', 'rule': {'kind': 'final'}}, variant: 'открывается через другой узел той же записи (viaTarget)'),
    Ev('conn', 'failing', {'app': 'org.telegram.messenger', 'host': 'api.telegram.org', 'port': 443, 'more': 2, 'outbound': 'proxy/vless[s1::n1]', 'route': 's1', 'kind': 'timeout', 'count': 7, 'windowMs': 60000, 'rule': {'kind': 'app', 'id': 'org.telegram.messenger', 'name': 'Telegram'}}, log: 1177),
  ],
  'rules': [
    Ev('rules', 'targetLost', {'rule': 'Streaming', 'target': 'chain:gone', 'why': 'deleted', 'to': 'block', 'more': 1}, variant: 'цель правила удалена'),
    Ev('rules', 'targetLost', {'app': 'Telegram', 'target': 'node:s2::b1', 'why': 'off', 'to': 'direct'}, variant: 'цель приложения выключена в Nodes'),
    Ev('rules', 'targetFound', {'rule': 'Streaming', 'target': 'src:s2'}, level: 'info'),
    Ev('rules', 'fallback', {'rule': 'Streaming', 'target': 'src:s2', 'to': 'direct'}),
    Ev('rules', 'targetBack', {'rule': 'Streaming', 'target': 'src:s2'}, level: 'info'),
    Ev('rules', 'ruleSetFailed', {'tag': 'geosite-ru', 'url': 'https://example.com/geosite-ru.srs', 'error': 'HTTP 503'}),
    Ev('rules', 'ruleSetUpdated', {'tag': 'geosite-ru'}, level: 'info'),
  ],
  'sub': [
    Ev('sub', 'failed', {'source': 's1', 'name': 'Remnawave', 'error': 'HTTP 403: request blocked'}, level: 'error'),
    Ev('sub', 'diverged', {'source': 's1', 'name': 'Remnawave', 'host': 'sub.example.com', 'ua': 'sing-box', 'directNodes': 12, 'tunnelNodes': 15, 'onlyDirect': <String>[], 'onlyTunnel': ['Helsinki 1 (1.1.1.1:443)', 'Warsaw (2.2.2.2:443)'], 'onlyTunnelCount': 3, 'directStatus': 200, 'tunnelStatus': 200, 'directMs': 1200, 'tunnelMs': 300, 'directPath': 'direct', 'tunnelPath': 'proxy', 'directFresh': {'lastModified': 'Mon, 12 Oct 2026 08:00:00 GMT'}, 'tunnelFresh': {'lastModified': 'Tue, 13 Oct 2026 08:00:00 GMT'}, 'used': 'tunnel', 'why': 'newer: lastModified'}),
    Ev('sub', 'updated', {'source': 's1', 'name': 'Remnawave', 'total': 42, 'added': 3, 'removed': 1}, level: 'info'),
    Ev('sub', 'removed', {'source': 's1', 'name': 'Remnawave', 'count': 2}),
    Ev('sub', 'back', {'source': 's1', 'name': 'Remnawave', 'count': 2}, level: 'info'),
    Ev('sub', 'dead', {'source': 's1', 'name': 'Remnawave'}),
    Ev('node', 'addressMissing', {'host': 'de1.bad-host.example', 'node': 'Frankfurt 1', 'source': 's1', 'nodes': 3, 'inUse': true}),
  ],
  'dns': [
    Ev('dns', 'failed', {'server': 'cloudflare', 'path': 'proxy', 'since': _now - 60000, 'provider': 'cloudflare', 'side': 'vpn', 'servers': ['cloudflare']}),
    Ev('dns', 'failedOnNode', {'server': 'cloudflare', 'path': 'proxy', 'since': _now - 60000, 'provider': 'cloudflare', 'side': 'vpn', 'node': 's1::n1', 'via': 's1::n2'}),
    Ev('dns', 'switched', {'side': 'vpn', 'from': 'cloudflare', 'to': 'google', 'reason': 'failover'}, level: 'info'),
  ],
  'auto': [
    Ev('auto', 'switched', {'route': 's1', 'from': 's1::n1', 'to': 's1::n2', 'reason': 'failover', 'fails': 3}, level: 'info'),
    Ev('auto', 'fastest', {'route': 's1', 'from': 's1::n1', 'to': 's1::n3'}, level: 'info'),
    Ev('auto', 'unstable', {'id': 's1', 'strikes': 3, 'holdMs': 600000}),
  ],
  'conn': [
    Ev('conn', 'lost', {}),
    Ev('conn', 'restored', {'downMs': 45000}, level: 'info'),
    Ev('conn', 'offline', {}),
    Ev('conn', 'online', {'downMs': 120000}, level: 'info'),
    Ev('conn', 'connectFailed', {'reason': 'Manual pick "Frankfurt 1" (Remnawave) is unavailable: the subscription no longer has it. The tunnel is not moved to another server — choose a server in Route.', 'fix': 'pick'}, level: 'error', variant: 'pinLost'),
    Ev('conn', 'connected', {'entry': 's1', 'server': 's1::n1', 'mode': 'tun', 'route': 'rules'}, level: 'info'),
    Ev('conn', 'disconnected', {'by': 'error', 'reason': 'sing-box exited'}, level: 'warn'),
    Ev('conn', 'vpnDown', {'causes': ['core'], 'proxy': 'kept'}, level: 'error', variant: 'sing-box не поднялся, системный прокси оставлен'),
    Ev('conn', 'vpnDown', {'causes': ['network'], 'source': 'platform'}, level: 'error', variant: 'нет сети'),
    Ev('conn', 'vpnDown', {'causes': ['core', 'network'], 'proxy': 'kept'}, level: 'error', variant: 'обе причины: core и network'),
    Ev('conn', 'vpnUp', {'downMs': 185000, 'causes': ['core']}, level: 'info', variant: 'закрыто: VPN снова работает'),
  ],
  'core': [
    Ev('core', 'crashed', {'code': 2}, level: 'error'),
    Ev('core', 'restarted', {'attempt': 1, 'downMs': 4200}, level: 'info'),
    Ev('core', 'restartFailed', {'attempt': 3, 'error': 'start service: listen tcp 127.0.0.1:2080: bind: address already in use'}, level: 'error'),
    Ev('core', 'tunNeedsAdmin', {'stage': 'start', 'error': 'Access is denied'}, level: 'error'),
    Ev('core', 'sysProxy', {'on': true, 'by': 'core', 'error': 'access denied'}),
    Ev('core', 'deprecated', {'text': 'legacy DNS server format is deprecated in sing-box 1.12'}),
    Ev('core', 'stateRestored', {'from': 'bak', 'reason': 'invalid', 'savedAt': _now - 3600000}),
    Ev('core', 'stateLost', {'reason': 'invalid'}, level: 'error'),
    Ev('core', 'tunTcpDead', {'stack': 'system', 'apps': ['org.telegram.messenger']}),
    Ev('core', 'tunTcpBack', {'stack': 'system', 'deadMs': 12000}, level: 'info'),
    Ev('speed', 'done', {'down': 92e6, 'up': 41e6, 'latency': 48}, level: 'info'),
    Ev('speed', 'failed', {'error': 'timed out'}),
  ],
  'update': [
    Ev('core', 'updateAvailable', {'version': '0.2.0', 'build': 41, 'channel': 'beta', 'forced': false, 'via': 'direct'}, level: 'info'),
    Ev('core', 'updateFailed', {'stage': 'download', 'code': 'http', 'error': 'HTTP 404', 'via': 'tunnel'}),
    Ev('core', 'updateChannelEmpty', {'channel': 'stable', 'attempts': [{'url': 'https://feed.example.com/stable.json', 'error': 'HTTP 404'}]}),
    Ev('core', 'updateDownloaded', {'version': '0.2.0', 'size': 25165824, 'via': 'tunnel'}, level: 'info'),
    Ev('core', 'updateDeltaFailed', {'error': 'hash mismatch', 'from': '0.1.0'}),
    Ev('core', 'updateInstalled', {'from': '0.1.0', 'to': '0.2.0'}, level: 'info'),
  ],
};

const _famTitle = {
  'site': 'Сайт не открывается / массовые сбои соединений',
  'rules': 'Правила: потерянная цель, If unavailable, наборы правил',
  'sub': 'Подписки и серверы',
  'dns': 'DNS',
  'auto': 'Auto: переключения и нестабильные записи',
  'conn': 'Соединение и ошибки подключения',
  'core': 'Ядро sing-box, TUN, TCP, сохранённые данные, спидтест',
  'update': 'Обновление приложения',
  'other': 'Прочие поверхности: тосты хоста, плашки на экранах',
};

const _when = {
  'site/unreachable': 'Сайт не открылся ни через один маршрут, сторож (Sentinel) подтвердил сбой. Уведомляет только когда внешний чекер check-host сказал «открывается из других стран»; остальные варианты — только запись в журнале.',
  'site/blocked': 'Сайт не открылся через маршрут, но открылся через другой (via) — «обходной путь есть»; предлагает создать правило.',
  'conn/failing': 'Много неудавшихся соединений одного приложения/адреса подряд, а проба сайта прошла (не вина сайта) или причина не ясна.',
  'rules/targetLost': 'Цель правила или приложения удалена / выключена / без серверов: трафик идёт по «If unavailable».',
  'rules/targetFound': 'Потерянная цель правила снова доступна.',
  'rules/fallback': 'Цель правила перестала отвечать: сработал «If unavailable».',
  'rules/targetBack': 'Цель, из-за которой сработал «If unavailable», снова отвечает.',
  'rules/ruleSetFailed': 'Набор правил (rule set) не скачался, используется последняя копия.',
  'rules/ruleSetUpdated': 'Набор правил обновлён.',
  'sub/failed': 'Не удалось загрузить или обновить подписку (HTTP/формат). Серверы последней удачной загрузки продолжают работать.',
  'sub/diverged': 'В Auto прямая и туннельная копии подписки отличаются набором серверов; применена одна из них.',
  'sub/updated': 'Подписка успешно обновилась (по умолчанию не уведомляет).',
  'sub/removed': 'Провайдер убрал серверы из подписки.',
  'sub/back': 'Убранные серверы вернулись.',
  'sub/dead': 'Серверы подписки не отвечают (пишет только мокап; ядро и приложение это событие не создают).',
  'node/addressMissing': 'Имя сервера узла не существует в DNS (проверено дважды). Уведомляет только если узел используется (inUse).',
  'dns/failed': 'DNS-сервер подтверждённо не отвечает ни напрямую, ни через запасную ноду.',
  'dns/failedOnNode': 'DNS-сервер стороны VPN молчит на ноде выхода в использовании, но отвечает через запасную.',
  'dns/switched': 'Автоматически сменился отвечающий DNS-сервер.',
  'auto/switched': 'Auto сам перешёл на другой сервер/запись.',
  'auto/fastest': 'Режим Fastest: сервер перестал быть самым быстрым, выбран новый.',
  'auto/unstable': 'Запись несколько раз подряд падала: Auto возвращается к ней не сразу (hold).',
  'conn/lost': 'Сеть пропала на живом подключении: ни один маршрут не отвечает.',
  'conn/restored': 'Сеть вернулась на живом подключении.',
  'conn/offline': 'Система сообщает: интернета нет вообще.',
  'conn/online': 'Интернет вернулся.',
  'conn/connectFailed': 'Подключение не удалось. Для Manual на потерянный сервер/запись (pinLost) — ошибка без подмены, работающее подключение завершается.',
  'conn/connected': 'Туннель поднят (журнальная запись).',
  'conn/disconnected': 'Туннель остановлен (по ошибке или пользователем).',
  'core/crashed': 'sing-box упал; ядро запускает его заново. Не уведомляет: если не поднялся за 30 с, строка вливается в conn/vpnDown.',
  'core/restarted': 'sing-box запущен заново после падения.',
  'core/restartFailed': 'Перезапуск sing-box не удался.',
  'conn/vpnDown': 'VPN не работает: sing-box не поднялся за 30 с (причина core) и/или нет сети (причина network). Одно событие на сбой, причины меняются на месте; уведомляет (connLost), плашка на Home.',
  'conn/vpnUp': 'VPN снова работает: закрывает conn/vpnDown, уведомление заменяется; перерыв — downMs.',
  'core/down': 'Больше не пишется (причина core у conn/vpnDown); в старом журнале — error.',
  'core/tunNeedsAdmin': 'TUN требует прав администратора (Windows).',
  'core/sysProxy': 'Системный прокси не удалось выставить/снять (или пользователь переключил).',
  'core/deprecated': 'sing-box предупредил об устаревшей настройке.',
  'core/stateRestored': 'Файл сохранённых данных был повреждён, восстановлен из резервной копии.',
  'core/stateLost': 'Файл сохранённых данных повреждён и не восстановлен, старт с пустого.',
  'core/tunTcpDead': 'TCP через TUN не доходит до маршрутизации (детектор осиротевших SYN).',
  'core/tunTcpBack': 'TCP через TUN снова идёт.',
  'speed/done': 'Спидтест завершён.',
  'speed/failed': 'Спидтест не удался.',
  'core/updateAvailable': 'Найдена новая версия приложения. Не уведомляет событием: у обновления своя поверхность (карточка Settings → Data и системное уведомление, см. update_*).',
  'core/updateFailed': 'Проверка / загрузка / проверка подписи / установка обновления не удалась.',
  'core/updateChannelEmpty': 'В выбранном канале нет релиза.',
  'core/updateDownloaded': 'Обновление скачано.',
  'core/updateDeltaFailed': 'Патч (delta) не скачался, качается полный файл.',
  'core/updateInstalled': 'Приложение обновлено.',
};

// the labels of the switches of Settings → Notifications (settings_look.dart), by switch key
final _kindRu = {
  'status': _en.statusNotification,
  'autoSwitch': _en.whenAutoSwitches,
  'unstable': _en.unstableEntry,
  'connLost': _en.connectionLost,
  'blocked': _en.siteDoesNotOpen,
  'dnsFailed': _en.dnsServerDoesNotAnswer,
  'subUpdated': _en.subscriptionUpdated,
  'subFailed': _en.subscriptionProblems,
  'ruleSets': _en.ruleSets,
  'updateAvailable': _en.newVersion,
  'appData': _en.appData,
};

String _help(String label, EventRecord e, CoreHost host) {
  final l = _en;
  if (label == l.checkWithChecker) return 'просит внешний чекер (check-host) открыть сайт из других стран; результат дописывается в то же событие, пока ждёт — «Checking…» (кнопка бледная).';
  if (label == l.checking) return 'чекер уже опрашивается, кнопка неактивна.';
  if (label == l.copySite) return 'копирует хост сайта в буфер, тост «copied».';
  if (label == l.createRule) return 'открывает форму нового правила с хостом; цель правила — маршрут via/viaTarget, через который сайт открылся.';
  if (label == l.ignoreSite) return 'добавляет сайт в игнорируемые (его сбои уходят из журнала), снекбар «… ignored» с Undo.';
  if (label == l.retry) {
    return switch (e.key) {
      'conn/connectFailed' => 'подключается заново (host.connect).',
      'sub/failed' => 'обновляет подписку заново (updateSource).',
      'rules/ruleSetFailed' => 'заново скачивает наборы правил (retryRuleSets).',
      'core/sysProxy' => 'снова включает системный прокси (setSysProxy(true)).',
      'core/updateFailed' || 'core/updateChannelEmpty' => 'заново проверяет обновление приложения (checkUpdate).',
      'speed/failed' => 'повторяет замер скорости (toggleSpeedTest).',
      _ when e.cat == 'core' => 'перезапускает ядро sing-box (host.retry); кнопки нет, пока ядро уже работает.',
      _ => 'повторяет действие события.',
    };
  }
  if (label == l.checkNow) return 'просит ядро заново проверить то, о чём событие (host.checkNow); пока идёт проверка, кнопка «Checking…» неактивна.';
  if (label == l.sendReport) return 'открывает экран «Send report»: отчёт разработчикам с этим событием.';
  if (label == l.inRawLog) return 'переключает на вкладку Raw и подсвечивает строку лога, записанную в тот же момент.';
  if (label == l.hideThisType) return 'скрывает этот тип событий фильтром журнала.';
  if (label == l.showOnlyThisType) return 'оставляет в журнале только события этого типа.';
  if (label == l.open) {
    final t = eventOpenTarget(e, host);
    return switch (t) {
      'rulelist' => 'открывает экран Rules (список правил).',
      'rules' => 'открывает Rules → Rule sets.',
      'dns' => 'открывает Settings → DNS.',
      null => 'ведёт в Nodes к карточке записи этой строки «via» (у каждой записи в блоке «почему» своя кнопка).',
      _ => 'открывает в Nodes карточку «$t» (подписка / запись).',
    };
  }
  return '';
}

/// What the button of a system notification does (id as in `SystemNotifier.eventActions`), per `_actFromShade` of home_shell.dart.
String _shadeHelp(String id, EventRecord e) => switch (id) {
  'rule' => 'приложение открывается на форме нового правила для сайта (via/viaTarget — цель)',
  'ignore' => 'сайт добавляется в игнорируемые, уведомление заменяется на «… added to ignored sites» с кнопкой Undo',
  'connect' => 'подключается (host.connect)',
  'retry' => switch (e.key) {
    'conn/connectFailed' => 'подключается заново (host.connect)',
    'core/sysProxy' => 'снова включает системный прокси (setSysProxy(true))',
    _ => 'перезапускает ядро (host.retry)',
  },
  'checkNow' => 'ядро заново проверяет то, о чём событие (host.checkNow по id события)',
  'retryRuleSets' => 'заново скачиваются наборы правил (host.retryRuleSets)',
  'networkSettings' => 'открываются системные настройки сети (host.openNetworkSettings)',
  'removeProxy' => 'снимается системный прокси (host.releaseSysProxy)',
  'reconnect' => 'отключается и подключается заново (disconnect + connect)',
  'retrySub' => 'обновляется подписка из data.source (host.updateSource); без source ничего не делает',
  'report' => 'открывается экран «Send report» с этим событием',
  'open' => 'приложение открывается на субъекте события (запись в Nodes, Rules, наборы правил, DNS), иначе на событии в Logs → Events',
  _ => 'id «$id»',
};

// ───────────────────────────── harness widgets ─────────────────────────────

AppLinks _fullLinks() => AppLinks(
  openNodesEntry: (_) {},
  openNodesAdd: ({tab}) {},
  openRules: ([_]) {},
  openRuleForm: (_) {},
  openAppAct: (_) {},
  openDns: () {},
  openRuleSets: () {},
  newRuleFor: ({host, app, via}) {},
  openRoute: ({edit = false}) {},
  openLogsEvent: (_) {},
);

// the app's theme, its fallback (the flags) extended by the stand-ins for Android's system symbol fonts
final _theme = () {
  final t = appThemes[AppThemeId.original]!;
  return t.copyWith(textTheme: t.textTheme.apply(fontFamilyFallback: const [kFlagsFontFamily, 'SegoeSym', 'SegoeEmoji']));
}();

class _Shell extends StatelessWidget {
  const _Shell({required this.host, required this.boundary, required this.child});
  final FakeCoreHost host;
  final GlobalKey boundary;
  final Widget child;

  @override
  Widget build(BuildContext context) => AppSettingsScope(
    settings: AppSettings(locale: const Locale('en')),
    child: CoreHostScope(
      host: host,
      child: AppLinksScope(
        links: _fullLinks(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme,
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Material(
            color: const Color(0xFF8A9099),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: _w, child: RepaintBoundary(key: boundary, child: child)),
            ),
          ),
        ),
      ),
    ),
  );
}

TextStyle _cap({double size = 12.5, bool bold = false, Color color = const Color(0xFF1B1F24)}) => TextStyle(
  fontFamily: 'Roboto',
  fontFamilyFallback: const ['Flags', 'SegoeSym', 'SegoeEmoji'],
  fontSize: size,
  height: 1.3,
  fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
  color: color,
  decoration: TextDecoration.none,
);

class _Caption extends StatelessWidget {
  const _Caption(this.lines);
  final List<(String, bool)> lines; // (text, bold)
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: const Color(0xFFF1EFE6),
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final (t, b) in lines) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(t, style: _cap(bold: b)))],
    ),
  );
}

class _Shade extends StatelessWidget {
  const _Shade(this.note);
  final SystemNote note;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: const Color(0xFF2B2D31),
    padding: const EdgeInsets.all(12),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF3A3D42), borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Jormungand · сейчас', style: _cap(size: 11, color: const Color(0xFF9AA0A6))),
          const SizedBox(height: 4),
          Text(note.title, style: _cap(size: 14, bold: true, color: Colors.white)),
          if (note.text.isNotEmpty) Text(note.text, style: _cap(size: 13, color: const Color(0xFFD0D3D7))),
          if (note.actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [for (final a in note.actions) Padding(padding: const EdgeInsets.only(right: 18), child: Text(a.$2.toUpperCase(), style: _cap(size: 12, bold: true, color: const Color(0xFF8AB4F8))))]),
          ],
        ],
      ),
    ),
  );
}

// ───────────────────────────── blocks and pages ─────────────────────────────

Future<void> _png(WidgetTester tester, ui.Image img, String name) async {
  await tester.runAsync(() async {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('${_out.path}/$name').writeAsBytes(data!.buffer.asUint8List());
  });
}

Future<ui.Image> _stack(WidgetTester tester, List<ui.Image> imgs) async {
  const gap = 12;
  final h = imgs.fold<int>(0, (n, i) => n + i.height + gap);
  return (await tester.runAsync(() async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, _w * _ratio, h.toDouble()), Paint()..color = const Color(0xFF8A9099));
    var y = 0.0;
    for (final i in imgs) {
      c.drawImage(i, Offset(0, y), Paint());
      y += i.height + gap;
    }
    return rec.endRecording().toImage((_w * _ratio).round(), h);
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await _loadFonts();
    await initializeDateFormatting('en');
    _out.createSync(recursive: true);
  });

  testWidgets('event screenshots', timeout: const Timeout(Duration(minutes: 15)), (tester) async {
    tester.view.devicePixelRatio = _ratio;
    tester.view.physicalSize = const Size(_w * _ratio, 3200);
    addTearDown(tester.view.reset);
    final host = _host();
    final boundary = GlobalKey();
    final io = FakeNotifyIo();

    Future<ui.Image> shoot(GlobalKey k) async => (await tester.runAsync(() async {
      final b = k.currentContext!.findRenderObject() as RenderRepaintBoundary;
      return b.toImage(pixelRatio: _ratio);
    }))!;

    Future<ui.Image> render(Widget w) async {
      await tester.pumpWidget(_Shell(host: host, boundary: boundary, child: w));
      await tester.pump();
      return shoot(boundary);
    }

    // ── EventRecord helpers ──
    var nextId = 1000;
    EventRecord rec(Ev e) => EventRecord(
      id: nextId++,
      at: _now - 4 * 60000,
      cat: e.cat,
      type: e.type,
      level: e.level,
      own: false,
      bg: e.bg,
      log: e.log,
      data: {...e.data},
    );
    final allOn = {for (final k in notifDefaults.keys) k: true};
    bool notifies(EventRecord r) => eventNotifies(allOn, r);
    String notifLine(EventRecord r) {
      final kind = eventNotifKind[r.key];
      if (kind == null) return 'Уведомление: нет — тип не в eventNotifKind, только запись в журнале.';
      if (!notifies(r)) return 'Уведомление: переключатель «${_kindRu[kind] ?? kind}», но этот вариант события не уведомляет (отсев по вердикту/чекеру/inUse/bg) — только журнал.';
      final dflt = notifAllows(null, kind) ? 'включён по умолчанию' : 'ВЫКЛЮЧЕН по умолчанию';
      return 'Уведомление: переключатель «${_kindRu[kind] ?? kind}» ($dflt)${r.bg ? '; bg-событие — ещё «Errors while the screen is off» (выкл. по умолчанию)' : ''}.';
    }

    List<String> labelsOf() => [for (final a in tester.widgetList<EventAct>(find.byType(EventAct))) a.label];

    // ───────── phase 1: toasts through the real app (HomeShell._notify / _toast) ─────────
    final toastImg = <String, (ui.Image, List<String>)>{}; // by event id / notice key
    final appKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: appKey, child: JormungandApp(coreHost: host)));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4)); // the first look at the journal is history

    // wait until exactly one SnackBar is on screen and has stopped moving (the old one is gone,
    // the new one finished entering): hideCurrentSnackBar + showSnackBar overlap for a while
    Future<void> settleToast() async {
      Rect? last;
      var steady = 0;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(SnackBar).evaluate().length != 1) {
          last = null;
          steady = 0;
          continue;
        }
        final r = tester.getRect(find.byType(SnackBar));
        steady = (last != null && r == last) ? steady + 1 : 0;
        last = r;
        if (steady >= 3) return;
      }
      fail('toast did not settle');
    }

    Future<(ui.Image, List<String>)> grabToast() async {
      await tester.pump();
      await settleToast();
      final snack = tester.getRect(find.byType(SnackBar));
      final labels = [
        for (final t in tester.widgetList<TextButton>(find.descendant(of: find.byType(SnackBar), matching: find.byType(TextButton)))) ((t.child as Text).data ?? ''),
        for (final a in tester.widgetList<SnackBarAction>(find.byType(SnackBarAction))) a.label,
      ];
      final full = await shoot(appKey);
      final top = (snack.top - 10).clamp(0.0, 4000.0);
      final hgt = full.height / _ratio - top;
      final img = (await tester.runAsync(() async {
        final r = ui.PictureRecorder();
        Canvas(r).drawImageRect(full, Rect.fromLTWH(0, top * _ratio, full.width.toDouble(), hgt * _ratio), Rect.fromLTWH(0, 0, full.width.toDouble(), hgt * _ratio), Paint());
        return r.endRecording().toImage(full.width, (hgt * _ratio).round());
      }))!;
      await tester.pump(const Duration(seconds: 7)); // the toast flies away on its own
      await tester.pump(const Duration(milliseconds: 600));
      return (img, labels);
    }

    // which events make a toast: ask the same gate the app uses; the toast is the real one
    final recs = <Ev, EventRecord>{};
    for (final fam in _events.values) {
      for (final e in fam) {
        final r = rec(e);
        recs[e] = r;
        if (!notifies(r)) continue;
        final added = host.addEvent(e.cat, e.type, level: e.level, data: {...e.data}, bg: e.bg, log: e.log);
        toastImg['${e.key}|${e.variant}'] = await grabToast();
        recs[e] = EventRecord.fromJson(added);
      }
    }
    // a toast after «Ignore site»
    host.addEvent('site', 'blocked', level: 'warn', data: {'host': 'video.example.net', 'entry': 's1', 'via': 's2'});
    await tester.pump();
    await settleToast();
    await tester.tap(find.descendant(of: find.byType(SnackBar), matching: find.text('Ignore site')));
    toastImg['ignored'] = await grabToast();
    // host notices (connect error, subscription errors ...)
    const notices = <(String, String, List<String>, String)>[
      ('connectFailed', 'Manual pick "Frankfurt 1" (Remnawave) is unavailable: the subscription no longer has it. The tunnel is not moved to another server — choose a server in Route.', [], 'Ошибка подключения (pinLost): Manual на пропавший сервер. Показывается в момент попытки подключиться, либо когда запущенное подключение завершено потерей закрепления. Дублируется событием conn/connectFailed.'),
      ('subFailed', '', ['Remnawave', 'HTTP 403: request blocked'], 'Первая загрузка подписки не удалась (рядом событие sub/failed и плашка на карточке подписки).'),
      ('updateFailed', '', ['Remnawave', 'timeout'], 'Обновление уже загруженной подписки не удалось.'),
      ('vpnDenied', 'VPN permission was not granted', [], 'Пользователь отказал в системном разрешении VPN при подключении (Android).'),
      ('reconnectFailed', 'Could not apply the new settings: sing-box did not start', [], 'Перезапуск туннеля с новым планом после правки настроек не удался.'),
      ('nothingInAuto', 'Nothing left in Auto — the connection stays until you disconnect', [], 'Пользователь выключил последнюю запись в Auto при работающем подключении.'),
      ('notSaved', 'disk full', ['disk full'], 'Состояние не удалось сохранить на диск.'),
      ('updateCheckFailed', 'Could not check for an update: HTTP 404', ['HTTP 404'], 'Ручная проверка обновления не удалась.'),
      ('warning', 'The Auto probe route is not reachable', [], 'Предупреждение ядра при подключении.'),
    ];
    final noticeHelp = <String, String>{};
    for (final (code, text, args, help) in notices) {
      host.notice(HostNotice(code, text.isEmpty ? '$code: ${args.join(' / ')}' : text, args: args));
      toastImg['notice:$code'] = await grabToast();
      noticeHelp[code] = help;
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));

    // ───────── phase 2: system notifications (SystemNotifier.postEvent) ─────────
    final logsForWords = LogsController(host)..l10n = _en;
    final words = logsForWords.words;
    final sys = SystemNotifier(host, io: io);
    final shade = <EventRecord, SystemNote>{};
    for (final r in recs.values) {
      if (!notifies(r)) continue;
      await sys.postEvent(r, words);
      shade[r] = io.posted.last;
    }
    // the update notifications (UpdateFlow)
    final uh = FakeCoreHost()..installable = true;
    for (final k in notifDefaults.keys) {
      uh.notif.setFlag(k, true);
    }
    final uio = FakeNotifyIo();
    final flow = UpdateFlow(uh, io: uio, l10n: () => _en, inBackground: () => true)..start();
    const offer = UpdOffer(version: '0.2.0', channel: 'beta', size: 25165824, notes: {});
    uh.update = const AppUpdate(phase: UpdPhase.available, current: '0.1.0', offer: offer);
    uh.changed();
    await tester.pump();
    await tester.pump();
    uh.installWanted = true;
    uh.update = const AppUpdate(phase: UpdPhase.ready, current: '0.1.0', offer: offer, file: '/data/u.apk');
    uh.changed();
    await tester.pump();
    await tester.pump();
    flow.dispose();

    // ───────── phase 3: blocks ─────────
    final families = <String, List<ui.Image>>{};
    final covered = <String, List<String>>{};
    void add(String fam, ui.Image img) => (families[fam] ??= []).add(img);

    Future<ui.Image> captioned(List<(String, bool)> lines, Widget subject) => render(Column(mainAxisSize: MainAxisSize.min, children: [_Caption(lines), subject]));

    String head(Ev e) => '${e.key}${e.variant.isEmpty ? '' : ' — ${e.variant}'}';

    for (final MapEntry(key: fam, value: list) in _events.entries) {
      for (final e in list) {
        final r = recs[e]!;
        final how = _when[e.key] ?? '';
        (covered[fam] ??= []).add(e.key);
        // toast + system notification
        final t = toastImg['${e.key}|${e.variant}'];
        if (t != null) {
          final lines = <(String, bool)>[
            (head(e), true),
            ('Форма: ТОСТ в приложении (снекбар над нижней панелью; приложение на экране). Тап по тексту — открывает Logs → Events на этом событии; без тапа через 6 с «улетает» в пункт Logs.', false),
            ('Когда: $how', false),
            (notifLine(r), false),
            for (final l in t.$2) ('• кнопка «$l» — ${_help(l, r, host)}', false),
          ];
          add(fam, await captioned(lines, RawImage(image: t.$1, scale: _ratio, fit: BoxFit.fill)));
          final n = shade[r];
          if (n != null) {
            final sl = <(String, bool)>[
              (head(e), true),
              ('Форма: СИСТЕМНОЕ УВЕДОМЛЕНИЕ (Android, приложение не на экране; в тексте уведомления только заголовок и деталь, схема — не нативный вид). Тап — открывает Logs → Events на событии.', false),
              ('Заголовок = title строки журнала, текст = detail.', false),
              for (final a in n.actions) ('• кнопка «${a.$2}» — ${_shadeHelp(a.$1, r)}.', false),
            ];
            add(fam, await captioned(sl, _Shade(n)));
          }
        }
        // the row: collapsed and open
        final g1 = EventGroup(r), g2 = EventGroup(r);
        final l1 = LogsController(host)..l10n = _en, l2 = LogsController(host)..l10n = _en;
        l2.openRows.add(g2.key);
        EventRow row(EventGroup g, LogsController l) => EventRow(group: g, logs: l, words: l.words, first: true);
        final sub = Column(mainAxisSize: MainAxisSize.min, children: [
          ColoredBox(color: const Color(0xFFF1EFE6), child: SizedBox(width: _w, child: Text(' свёрнутая строка', style: _cap(size: 11)))),
          Container(color: appThemes[AppThemeId.original]!.scaffoldBackgroundColor, child: row(g1, l1)),
          ColoredBox(color: const Color(0xFFF1EFE6), child: SizedBox(width: _w, child: Text(' она же раскрытая (тап по строке)', style: _cap(size: 11)))),
          Container(color: appThemes[AppThemeId.original]!.scaffoldBackgroundColor, child: row(g2, l2)),
        ]);
        await render(sub);
        final labels = labelsOf().toSet().toList();
        final lines = <(String, bool)>[
          (head(e), true),
          ('Форма: СТРОКА в Logs → Events — свёрнутая (с кнопками) и раскрытая (все поля data + «Hide this type» / «Show only this type»).', false),
          ('Когда: $how', false),
          if (t == null) (notifLine(r), false),
          if (e.level != 'info') ('Уровень ${e.level}: цветная полоска слева и метка ${e.level == 'warn' ? 'WARN' : 'ERROR'}${e.bg ? '; значок «background» — случилось при погашенном экране' : ''}.', false),
          ('Тап по строке — раскрыть/свернуть.', false),
          for (final l in labels) ('• кнопка «$l» — ${_help(l, r, host)}', false),
        ];
        add(fam, await captioned(lines, sub));
        l1.dispose();
        l2.dispose();
      }
    }

    // update notifications
    for (final (n, what) in [for (final n in uio.updatePosted) (n, n.install ? 'готово к установке (скачано)' : 'доступна новая версия')]) {
      add('update', await captioned([
        ('Системное уведомление приложения об обновлении (UpdateFlow) — $what', true),
        ('Форма: СИСТЕМНОЕ УВЕДОМЛЕНИЕ, не событие журнала; приложение не на экране; переключатель «New version» (updateAvailable). «Available» — один раз на версию.', false),
        ('Тап открывает Settings → Data (карточка обновления).${n.install ? ' Кнопка «${n.installLabel}» — сразу отдаёт скачанный APK системному установщику.' : ''}', false),
      ], _Shade(SystemNote(id: 0, title: n.title, text: n.text, actions: n.install ? [('install', n.installLabel)] : const []))));
    }
    (covered['update'] ??= []).add('UpdateFlow notifications');

    // other surfaces
    add('other', await captioned([
      ('Плашка VPN down на Home (conn/vpnDown)', true),
      ('Форма: красная плашка вверху Home, пока VPN не работает (причина core: sing-box не вернулся) — сопровождает событие conn/vpnDown. Кнопки: «Retry» — повторить запуск ядра (host.retry); «Disable system proxy» — снять системный прокси, чтобы вернуть интернет (host.releaseSysProxy).', false),
    ], VpnAlert(host: host..setPhase(ConnectionPhase.connected, down: VpnDown(since: _now - 40000, proxy: 'kept')))));
    host.setPhase(ConnectionPhase.disconnected);
    final failedSrc = host.catalog.sourcesData['s1']!..unknown['lastError'] = {'msg': 'HTTP 403: request blocked', 'at': _now - 120000};
    add('other', await captioned([
      ('Плашка ошибки на карточке подписки (sub/failed)', true),
      ('Форма: строка на карточке подписки в Nodes, остаётся пока ошибка не снята. Кнопка «Retry» — обновить подписку заново.', false),
    ], Container(color: appThemes[AppThemeId.original]!.scaffoldBackgroundColor, padding: const EdgeInsets.fromLTRB(14, 12, 0, 0), child: SourceErrorStrip(source: failedSrc, updating: false, onRetry: () {}))));
    final ig = toastImg['ignored']!;
    add('other', await captioned([
      ('Снекбар после «Ignore site»', true),
      ('Форма: тост. Показывается после нажатия «Ignore site» (в строке, в тосте события). «Undo» — вернуть сайт из игнорируемых; исчезает сам через 6 с.', false),
    ], RawImage(image: ig.$1, scale: _ratio, fit: BoxFit.fill)));
    for (final (code, _, _, _) in notices) {
      final t = toastImg['notice:$code']!;
      add('other', await captioned([
        ('Тост хоста: HostNotice «$code»', true),
        ('Форма: простой тост (без кнопок, не событие журнала). ${noticeHelp[code]}', false),
        ('Тап по тексту ничего не делает; исчезает через ~4 с.', false),
      ], RawImage(image: t.$1, scale: _ratio, fit: BoxFit.fill)));
      (covered['other'] ??= []).add('notice:$code');
    }

    // ── pages ──
    final files = <String, List<String>>{};
    for (final MapEntry(key: fam, value: imgs) in families.entries) {
      var pages = <List<ui.Image>>[[]];
      var h = 0;
      for (final i in imgs) {
        if (h + i.height > _maxPage && pages.last.isNotEmpty) {
          pages.add([]);
          h = 0;
        }
        pages.last.add(i);
        h += i.height + 12;
      }
      for (var p = 0; p < pages.length; p++) {
        final name = '${fam}_${p + 1}.png';
        await _png(tester, await _stack(tester, pages[p]), name);
        (files[fam] ??= []).add(name);
      }
    }

    // ── index.png and README.md ──
    final idx = <(String, bool)>[('Индекс: как приложение показывает события сейчас', true), ('Тема original (тёмная), EN, ширина 400 px, масштаб 2. Подписи — тестовые.', false)];
    for (final f in files.entries) {
      idx.add(('${_famTitle[f.key]}: ${f.value.join(', ')}', true));
      idx.add((covered[f.key]!.toSet().join(', '), false));
    }
    idx.add(('Формы события: тост (в приложении) → системное уведомление (в фоне) → строка в Logs → Events (свёрнутая / раскрытая).', false));
    await _png(tester, await _stack(tester, [await render(_Caption(idx))]), 'index.png');
    final readme = StringBuffer('# Как приложение показывает события сейчас\n\nТема original (тёмная), английский UI, ширина 400 px, масштаб 2. Сгенерировано `flutter test test/_shots/event_shots_test.dart --run-skipped`.\n'
        'Подпись над каждым кадром (русская, тестовая) — тип события, когда появляется, форма, кнопки.\n\n- `index.png` — обзор: семейства, файлы, типы событий.\n');
    for (final f in files.entries) {
      readme.writeln('- ${f.value.map((n) => '`$n`').join(', ')} — ${_famTitle[f.key]}: ${covered[f.key]!.toSet().join(', ')}.');
    }
    readme.writeln('\nФормы: тост (настоящий `HomeShell._notify`, в кадре видна нижняя панель), системное уведомление (настоящие `SystemNotifier.postEvent` / `UpdateFlow`, рисуется схемой), строка Logs (настоящий `EventRow`, свёрнутая и раскрытая).');
    readme.writeln('Шрифты: Roboto и Material Icons из Flutter SDK, Twemoji flags из приложения (флаги в тексте — его глифами). Системного эмодзи-шрифта Android в тесте нет: ⚠️ ✅ → рисуются Segoe UI Symbol / Emoji этой Windows-машины (одноцветно, не как на Android; нет шрифта — квадрат).');
    await tester.runAsync(() => File('${_out.path}/README.md').writeAsString(readme.toString()));
  });
}
