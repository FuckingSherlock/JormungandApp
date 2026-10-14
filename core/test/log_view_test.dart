import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> ev(int id, String cat, String type, {int at = 0, String level = 'info', bool own = false, Map<String, dynamic> data = const {}}) =>
    {'id': id, 'at': at, 'cat': cat, 'type': type, 'level': level, 'own': own, 'data': data};

EventRecord e(Map<String, dynamic> m) => EventRecord.fromJson(m);

void main() {
  const min = 60 * 1000;

  test('the same event within 10 minutes is one row at its last place, with the worst level', () {
    final g = foldEvents([
      e(ev(1, 'site', 'blocked', at: 0, data: {'host': 'a.com', 'entry': 'e'})),
      e(ev(2, 'conn', 'lost', at: 1 * min)),
      e(ev(3, 'site', 'blocked', at: 5 * min, level: 'warn', data: {'host': 'a.com', 'entry': 'e'})),
      e(ev(4, 'site', 'blocked', at: 20 * min, data: {'host': 'a.com', 'entry': 'e'})),
      e(ev(5, 'site', 'blocked', at: 21 * min, data: {'host': 'b.com', 'entry': 'e'})),
    ]);
    expect(g.map((x) => x.items.map((i) => i.id).toList()), [
      [2],
      [1, 3],
      [4],
      [5],
    ]);
    expect(g[1].level, 'warn');
    expect(g[1].at, 5 * min);
    expect(g[1].ev.id, 3);
  });

  test('user actions fold by their data, subscriptions by source', () {
    final g = foldEvents([
      e(ev(1, 'user', 'mode', own: true, data: {'value': 'tun'})),
      e(ev(2, 'user', 'mode', own: true, data: {'value': 'proxy'})),
      e(ev(3, 'sub', 'updated', data: {'source': 's1', 'total': 3})),
      e(ev(4, 'sub', 'updated', data: {'source': 's1', 'total': 4})),
    ]);
    expect(g.length, 3);
    expect(g.last.items.length, 2);
  });

  test('filter: own hidden unless shown, problems, switched-off types, the text', () {
    final f = EventFilter();
    String text(EventRecord x) => '${x.type} ${x.data.values.join(' ')}';
    bool vis(EventRecord x, {bool own = false}) => f.visible(x, showOwn: own, text: text);
    final user = e(ev(1, 'user', 'connect', own: true));
    final warn = e(ev(2, 'conn', 'lost', level: 'warn'));
    final info = e(ev(3, 'sub', 'updated', data: {'name': 'Alpha'}));
    expect(vis(user), isFalse);
    expect(vis(user, own: true), isTrue);
    f.problems = true;
    expect([vis(warn), vis(info)], [true, false]);
    f.problems = false;
    f.toggleType('conn/lost');
    expect(vis(warn), isFalse);
    expect(f.offCats.map((c) => c.$1), ['conn']);
    expect(f.typesOn(f.offCats.first), 7, reason: 'conn has seven types in the catalog (failing among them)');
    f.q = 'alph';
    expect(vis(info), isTrue);
    expect(f.count, 2);
    f.toggleCat('sub');
    expect(f.off.where((k) => k.startsWith('sub/')).length, 6);
    f.toggleCat('sub');
    expect(f.off.any((k) => k.startsWith('sub/')), isFalse);
    f.reset();
    expect(f.count, 0);
  });

  test('EventFeed: first page is history (no notify), then fresh ones notify unless own; a restart of numbering resets', () {
    final feed = EventFeed();
    var r = feed.apply({'events': [ev(0, 'conn', 'connected'), ev(1, 'conn', 'lost')], 'next': 2, 'first': 0});
    expect(r.fresh.length, 2);
    expect(r.notify, isEmpty);
    r = feed.apply({'events': [ev(2, 'conn', 'restored'), ev(3, 'user', 'connect', own: true)], 'next': 4});
    expect(r.notify.map((x) => x.id), [2]);
    r = feed.apply({'events': [ev(3, 'user', 'connect', own: true)], 'next': 4}); // the same again: nothing new
    expect(r.fresh, isEmpty);
    expect(feed.list.length, 4);
    r = feed.apply({'events': [], 'next': 4, 'first': 2}); // pruned
    expect(feed.list.map((x) => x.id), [2, 3]);
    r = feed.apply({'events': [ev(0, 'conn', 'connected')], 'next': 1});
    expect(r.reset, isTrue);
    expect(feed.list, isEmpty);
    expect(feed.next, isNull);
  });

  test('LogCfg survives its JSON; unread ranges', () {
    final cfg = LogCfg(showOwn: true, seen: {3, 1}, rawTop: 9, rawUnread: {5, 6, 7, 9});
    final j = cfg.toJson();
    expect(j['rawUnread'], [5, 7, 9, 9]);
    expect(j['seen'], [1, 3]);
    final back = LogCfg.fromJson(j);
    expect(back.rawUnread, {5, 6, 7, 9});
    expect(back.rawTop, 9);
    expect(back.showOwn, isTrue);
    expect(LogCfg.fromJson(null).rawTop, isNull);
    expect(LogCfg.fromJson({'rawTop': -1}).rawTop, -1);
    expect(LogCfg.fromJson({'rawTop': -5}).rawTop, isNull);
  });

  Map<String, dynamic> line(int n, String lvl, String msg, {String src = 'sing-box', int t = 1000}) => {'n': n, 't': t, 'src': src, 'lvl': lvl, 'msg': msg};

  test('LogFeed: a first run reads what the core holds as read; later lines are unread until marked', () {
    final feed = LogFeed(LogCfg());
    var r = feed.apply({'lines': [line(0, 'info', 'a'), line(1, 'warn', 'b')], 'next': 2});
    expect(r.fresh.length, 2);
    expect(feed.cfg.rawUnread, isEmpty);
    expect(feed.cfg.rawTop, 1);
    feed.apply({'lines': [line(2, 'error', 'c'), line(3, 'info', 'd')], 'next': 4});
    expect(feed.cfg.rawUnread, {2, 3});
    expect(feed.unread.map((l) => l.n), [2, 3]);
    expect(feed.markRead([2]), isTrue);
    expect(feed.markRead([2]), isFalse);
    expect(feed.cfg.rawUnread, {3});
    expect(feed.shown('warn', '').map((l) => l.n), [1, 2]);
    expect(feed.shown('all', 'D').map((l) => l.n), [3]);
    expect(feed.shown('all', 'core').length, 0);
    feed.clear();
    expect(feed.lines, isEmpty);
    expect(feed.cfg.rawUnread, isEmpty);
    // the core restarted: numbers start over
    final r2 = feed.apply({'lines': [], 'next': 1});
    expect(r2.reset, isTrue);
    expect(feed.cfg.rawTop, -1);
  });

  test('LogFeed: failed lines of ignored sites are hidden until the chip is on; the list applies to old lines too', () {
    final cfg = LogCfg();
    final feed = LogFeed(cfg);
    feed.apply({
      'lines': [
        line(0, 'warn', 'outbound connection to api.dead.example.com:443: timeout'),
        line(1, 'error', 'other.org: refused'),
        line(2, 'info', 'dead.example.com is only mentioned'),
      ],
      'next': 3,
    });
    expect(feed.shown('all', '').length, 3);
    expect(feed.ignoredCount, 0);
    feed.setIgnored(IgnoredSites(['dead.example.com']));
    expect(feed.ignoredCount, 1, reason: 'only problem lines count');
    expect(feed.shown('all', '').map((l) => l.n), [1, 2]);
    expect(feed.visibleCount, 2);
    feed.apply({'lines': [line(3, 'warn', 'dead.example.com: reset')], 'next': 4});
    expect(feed.ignoredCount, 2);
    cfg.showIgnored = true;
    expect(feed.shown('all', '').length, 4);
    expect(LogCfg.fromJson(cfg.toJson()).showIgnored, isTrue);
    expect(LogCfg().showIgnored, isFalse, reason: 'off by default');
    feed.setIgnored(IgnoredSites());
    expect(feed.ignoredCount, 0);
  });

  test('LogFeed: unread below the oldest kept line are dropped', () {
    final cfg = LogCfg(rawTop: 3, rawUnread: {0, 1, 2});
    final feed = LogFeed(cfg);
    feed.apply({'lines': [line(2, 'info', 'x'), line(3, 'info', 'y')], 'next': 4});
    expect(cfg.rawUnread, {2});
  });

  test('notifications: the master switch and the kind decide; defaults as in Settings', () {
    expect(notifAllows(null, 'autoSwitch'), isTrue);
    expect(notifAllows(null, 'coreCrash'), isFalse);
    expect(notifAllows({'enabled': false}, 'autoSwitch'), isFalse);
    expect(notifAllows({'coreCrash': true}, 'coreCrash'), isTrue);
    expect(notifAllows({'autoSwitch': false}, 'autoSwitch'), isFalse);
    expect(eventNotifKind['site/blocked'], 'blocked');
    expect(eventNotifKind['conn/failing'], 'blocked');
    expect(eventNotifKind['core/tunTcpDead'], 'connLost');
    expect(eventNotifKind['core/tunTcpBack'], 'connLost');
    for (final t in ['updateAvailable', 'updateFailed', 'updateChannelEmpty', 'updateDownloaded', 'updateDeltaFailed', 'updateInstalled']) {
      expect(eventNotifKind.containsKey('core/$t'), isFalse, reason: 'the app update has its own surface, not a notification');
    }
  });

  test('judged events: only a confirmed root notifies; site/blocked (a workaround) as before', () {
    EventRecord j(String type, String? verdict, {int? cause}) =>
        e({...ev(1, type == 'blocked' ? 'site' : 'conn', type, level: 'warn'), 'verdict': ?verdict, 'cause': ?cause});
    expect(eventNotifies(null, j('failing', 'confirmed')), isTrue);
    expect(eventNotifies(null, j('failing', 'confirmed', cause: 7)), isFalse, reason: 'a consequence');
    for (final v in ['blip', 'consequence', 'workaround', 'unexplained']) {
      expect(eventNotifies(null, j('failing', v)), isFalse, reason: v);
    }
    expect(eventNotifies(null, j('failing', null)), isTrue, reason: 'not judged: the type decides');
    expect(eventNotifies(null, j('blocked', 'workaround')), isTrue);
  });

  test('site/unreachable with a check: only «opens» (not manual) notifies; without a check as before', () {
    EventRecord gone(Object? check) => e(ev(1, 'site', 'unreachable', level: 'warn', data: {'host': 'a.com', 'check': ?check}));
    expect(eventNotifies(null, gone(null)), isTrue, reason: 'retries off / an older event: as before');
    for (final s in ['pending', 'off', 'down', 'failed']) {
      expect(eventNotifies(null, gone({'state': s})), isFalse, reason: s);
    }
    expect(eventNotifies(null, gone({'state': 'opens'})), isTrue);
    expect(eventNotifies(null, gone({'state': 'opens', 'manual': true})), isFalse, reason: 'the user pressed the button: they look');
    expect(eventNotifies({'blocked': false}, gone({'state': 'opens'})), isFalse, reason: 'the kind still decides');
    expect(eventNotifies(null, e(ev(2, 'site', 'blocked', level: 'warn', data: {'host': 'a.com', 'check': {'state': 'pending'}}))), isTrue,
        reason: 'only unreachable has a check');
  });

  test('EventFeed: an event changed in place is replaced by its newer rev, notified once when it newly may', () {
    final feed = EventFeed();
    Map page({List<Map> events = const [], List<Map> updated = const [], int next = 2}) => {'events': events, 'updated': updated, 'next': next, 'first': 0};
    Map gone(int rev, String state) => {...ev(1, 'site', 'unreachable', level: 'warn', data: {'host': 'a.com', 'check': {'state': state}}), 'rev': rev};
    var r = feed.apply(page(events: [gone(0, 'pending')], next: 1));
    expect(r.notify.map((x) => x.id), [1], reason: 'the first page: the caller still asks eventNotifies, which says no for pending');
    expect(eventNotifies(null, r.notify.single), isFalse);
    r = feed.apply(page(updated: [gone(1, 'opens')]));
    expect([r.changed, r.fresh], [true, isEmpty]);
    expect(feed.list.single.rev, 1);
    expect(feed.list.single.data['check'], {'state': 'opens'});
    expect(r.notify.map((x) => x.id), [1]);
    expect(eventNotifies(null, r.notify.single), isTrue);
    r = feed.apply(page(updated: [gone(1, 'opens')]));
    expect([r.changed, r.notify], [false, isEmpty], reason: 'the same rev again: nothing');
    r = feed.apply(page(updated: [{...gone(1, 'opens'), 'id': 77}]));
    expect(r.changed, isFalse, reason: 'an event the list does not hold is ignored');
  });

  test('EventFeed: a repeat of an event (data.repeat) changes it in place, notifies once at most; the row counts and lists the times', () {
    final feed = EventFeed();
    Map page({List<Map> events = const [], List<Map> updated = const []}) => {'events': events, 'updated': updated, 'next': 2, 'first': 0};
    Map blocked(int rev, {List<int>? at}) => {
          ...ev(1, 'site', 'blocked', at: 100, level: 'info', data: {'host': 'a.com', 'entry': 'A', if (at != null) 'repeat': {'count': at.length, 'firstAt': at.first, 'lastAt': at.last, 'at': at}}),
          'verdict': 'workaround',
          'rev': rev,
        };
    feed.apply({'events': [], 'next': 1, 'first': 0});
    var r = feed.apply(page(events: [blocked(0)]));
    expect(feed.markNotified(r.notify.single.id), isTrue, reason: 'the first occurrence notifies');
    r = feed.apply(page(updated: [blocked(1, at: [100, 700])]));
    expect(feed.markNotified(r.notify.single.id), isFalse, reason: 'its repeat does not notify again, though eventNotifies is still yes');
    expect(eventNotifies(null, r.notify.single), isTrue);
    final g = foldEvents(feed.list).single;
    expect([g.times, g.lastAt, feed.list.single.occurrences], [2, 700, [100, 700]]);
    expect(feed.list.single.at, 100);
  });

  test('background events (screen off): notify only with «bgErrors»; the filter hides them', () {
    final bg = e({...ev(1, 'site', 'blocked', level: 'warn', data: {'host': 'a.com'}), 'bg': true});
    final fg = e(ev(2, 'site', 'blocked', level: 'warn', data: {'host': 'a.com'}));
    expect([bg.bg, fg.bg], [true, false]);
    expect(eventNotifies(null, fg), isTrue);
    expect(eventNotifies(null, bg), isFalse, reason: 'off by default');
    expect(eventNotifies({'bgErrors': true}, bg), isTrue);
    expect(eventNotifies({'bgErrors': true, 'blocked': false}, bg), isFalse, reason: 'the kind still decides');
    expect(eventNotifies({'bgErrors': true, 'enabled': false}, bg), isFalse);
    expect(eventNotifies({'bgErrors': false}, fg), isTrue, reason: 'normal events do not care');
    final f = EventFilter();
    String text(EventRecord x) => '';
    expect(f.visible(bg, showOwn: false, text: text), isTrue, reason: 'shown by default');
    f.hideBg = true;
    expect(f.count, 1);
    expect(f.visible(bg, showOwn: false, text: text), isFalse);
    expect(f.visible(fg, showOwn: false, text: text), isTrue);
    f.reset();
    expect([f.hideBg, f.count], [false, 0]);
  });

  test('log text, groups and days', () {
    final l = LogLine.fromJson(line(1, 'warn', 'm', src: 'core', t: 5000));
    expect(l.groupKey, '5|warn|core');
    expect(rawLogText([l]), '1970-01-01T00:00:05.000Z WARN  [core] m');
    final now = DateTime(2026, 3, 10, 12).millisecondsSinceEpoch;
    expect(daysAgo(DateTime(2026, 3, 10, 1).millisecondsSinceEpoch, now), 0);
    expect(daysAgo(DateTime(2026, 3, 9, 23).millisecondsSinceEpoch, now), 1);
    expect(daysAgo(DateTime(2026, 3, 1).millisecondsSinceEpoch, now), 9);
  });
}
