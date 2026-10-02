/// Number formats of Home (mockup `fmtRate` / `fmtBytes` in 50-home.js, `evDuration` in 47-events.js).
/// Units are not translated (the mockup keeps them in Latin too).
library;

/// `(value, unit)` of a speed in bytes per second; the value stays within 5 characters by
/// switching units (`999.9` max), one decimal only under 10 of KB/s and above.
(String, String) fmtRate(num bytes) {
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  var b = bytes.toDouble(), i = 0;
  while (b >= 1000 && i < 3) {
    b /= 1024;
    i++;
  }
  return (i > 0 && b < 10 ? b.toStringAsFixed(1) : '${b.round()}', units[i]);
}

/// A total in bytes: `1.84 GB`, `312 MB`, `87.3 MB`.
String fmtBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var b = bytes.toDouble(), i = 0;
  while (b >= 1000 && i < 4) {
    b /= 1024;
    i++;
  }
  final v = i > 0 && b < 10
      ? b.toStringAsFixed(2)
      : i > 0 && b < 100
      ? b.toStringAsFixed(1)
      : '${b.round()}';
  return '$v ${units[i]}';
}

/// The unit a [Duration] is shown in (`evDuration`): under 90 s seconds, under 90 min minutes,
/// else hours and minutes. The widget turns it into text with the ARB keys `s` / `min` / `hMin`.
enum DurationUnit { seconds, minutes, hoursMinutes }

({DurationUnit unit, int a, int b}) splitDuration(Duration d) {
  final s = (d.inMilliseconds / 1000).round();
  if (s < 90) return (unit: DurationUnit.seconds, a: s, b: 0);
  if (s < 5400) return (unit: DurationUnit.minutes, a: (s / 60).round(), b: 0);
  return (
    unit: DurationUnit.hoursMinutes,
    a: s ~/ 3600,
    b: ((s % 3600) / 60).round(),
  );
}

/// ISO 3166 alpha-2 -> flag emoji; the globe for anything else (`flagOf`).
String flagOf(String? country) {
  final cc = (country ?? '').toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(cc)) return '\u{1F310}';
  return String.fromCharCodes([for (final c in cc.codeUnits) 0x1F1E6 + c - 65]);
}
