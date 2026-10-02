import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../core/format.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';

/// Row 1 of Home (`.row1`): the Speed card on the left, Exit IP over Connections on the right.
/// The cards are as tall as the right column; every line is one non-wrapping line and numbers sit
/// in fixed-width slots, so live values never move the labels or resize the cards.
class StatCards extends StatelessWidget {
  const StatCards({super.key, required this.host});

  final CoreHost host;

  @override
  Widget build(BuildContext context) {
    final connected = host.isOn;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SpeedCard(traffic: host.traffic, connected: connected),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExitIpCard(host: host),
                const SizedBox(height: 10),
                ConnectionsCard(traffic: host.traffic, connected: connected),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `.row1 .card-label`: 11 px caps label of the stat cards.
class StatLabel extends StatelessWidget {
  const StatLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        height: 15 / 11,
        fontWeight: FontWeight.w600,
        letterSpacing: .5,
        color: context.colors.t3,
      ),
    );
  }
}

/// Speed (live, bytes per second) over This session (totals), split by a divider that sits level
/// with the gap between the two cards on the right.
class SpeedCard extends StatelessWidget {
  const SpeedCard({super.key, required this.traffic, required this.connected});

  final TrafficInfo traffic;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final (dv, du) = fmtRate(connected ? traffic.down : 0);
    final (uv, uu) = fmtRate(connected ? traffic.up : 0);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatLabel(l10n.speed),
                  const SizedBox(height: 4),
                  _RateRow(down: true, value: dv, unit: du),
                  _RateRow(down: false, value: uv, unit: uu),
                ],
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: c.border),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatLabel(l10n.thisSession),
                    const SizedBox(height: 4),
                    _TotalRow(down: true, bytes: traffic.downTotal),
                    _TotalRow(down: false, bytes: traffic.upTotal),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.down, required this.size});

  final bool down;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      down ? '↓' : '↑',
      style: monoText.copyWith(
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: down ? c.accent : c.warn,
      ),
    );
  }
}

/// `.stat-row`: arrow, the value in a 5-character slot, the unit.
class _RateRow extends StatelessWidget {
  const _RateRow({required this.down, required this.value, required this.unit});

  final bool down;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          _Arrow(down: down, size: 13),
          const SizedBox(width: 4),
          SizedBox(
            width: monoSlot(context, 5, 15),
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              style: monoText.copyWith(
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w600,
                color: c.t1,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(unit, style: monoText.copyWith(fontSize: 11, color: c.t2)),
        ],
      ),
    );
  }
}

/// `.stat-total-row`: arrow at the left, the total at the right.
class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.down, required this.bytes});

  final bool down;
  final num bytes;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: monoSlot(context, 13, 13),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            _Arrow(down: down, size: 12),
            Text(
              fmtBytes(bytes),
              maxLines: 1,
              style: monoText.copyWith(
                fontSize: 13,
                height: 16 / 13,
                fontWeight: FontWeight.w500,
                color: c.t1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Exit IP card: where traffic leaves while connected, the device's own address while not
/// ("Direct IP"). A tap checks again.
class ExitIpCard extends StatelessWidget {
  const ExitIpCard({super.key, required this.host});

  final CoreHost host;

  /// (flag, address, location line) of an exit state (`renderExitIp`).
  static (String, String, String) _texts(AppLocalizations l10n, ExitState e) {
    const globe = '\u{1F310}';
    if (e.checking) return (globe, '…', l10n.checking);
    if (e.error) return (globe, l10n.noAnswer2, l10n.tapToRetry);
    final where = [
      if ((e.city ?? '').isNotEmpty) e.city!,
      if ((e.country ?? '').isNotEmpty) e.country!,
    ].join(', ');
    return (
      flagOf(e.country),
      e.ip ?? '',
      where.isEmpty ? l10n.locationUnknown : where,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final e = host.exit;
    final label = host.isOn && !host.busy ? l10n.exitIp : l10n.directIp;
    final (flag, ip, loc) = _texts(l10n, e);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: host.refreshExit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: StatLabel(label)),
              const SizedBox(width: 6),
              SizedBox(
                width: 20,
                child: Text(
                  flag,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(fontSize: 15, height: 1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ip,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoText.copyWith(
                    fontSize: 13,
                    height: 18 / 13,
                    fontWeight: FontWeight.w600,
                    color: c.t1,
                  ),
                ),
                Text(
                  loc,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, height: 16 / 12, color: c.t2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Open connections: the total, TCP and UDP stacked after it.
// TODO(ui): a tap opens the Live connections sheet (mockup 76-conns.js).
class ConnectionsCard extends StatelessWidget {
  const ConnectionsCard({
    super.key,
    required this.traffic,
    required this.connected,
  });

  final TrafficInfo traffic;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tcp = connected ? traffic.tcp : 0;
    final udp = connected ? traffic.udp : 0;
    Widget split(String name, int n, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          style: monoText.copyWith(fontSize: 12, height: 17 / 12, color: color),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: monoSlot(context, 3, 12),
          child: Text(
            '$n',
            textAlign: TextAlign.right,
            style: monoText.copyWith(
              fontSize: 12,
              height: 17 / 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatLabel(context.l10n.connections),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: monoSlot(context, 3, 18),
                    child: Text(
                      '${connected ? traffic.connections : 0}',
                      maxLines: 1,
                      style: monoText.copyWith(
                        fontSize: 18,
                        height: 1,
                        fontWeight: FontWeight.w600,
                        color: c.t1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      split('TCP', tcp, c.accent),
                      split('UDP', udp, c.purple),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
