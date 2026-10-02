/// Small JSON helpers of the catalog models (docs/core.md → «Модель каталога (Dart)»).
///
/// Every model reads and writes the same JSON the mockup keeps (`liveSnapshot()` in
/// 95-live.js). Keys a model does not know stay in [RoundTrip.unknown] and are written
/// back untouched; a known key the input did not have is not written while its value is
/// still the default ([RoundTrip.put] with `omit`), so reading a snapshot and writing it
/// again gives the same JSON.
library;

typedef Json = Map<String, dynamic>;

/// JavaScript truthiness (the mockup tests `s.enabled`, `e.inAuto`… that way).
bool truthy(Object? v) => v != null && v != false && v != 0 && v != '' && !(v is double && v.isNaN);

List<String> strList(Object? v) => v is List ? [for (final x in v) '$x'] : <String>[];

Json asJson(Object? v) => v is Map ? Json.from(v) : Json();

Object? deepCopy(Object? v) => switch (v) {
      Map() => {for (final e in v.entries) '${e.key}': deepCopy(e.value)},
      List() => [for (final x in v) deepCopy(x)],
      _ => v,
    };

/// Remembers which keys the input had and keeps the ones the model does not know.
mixin RoundTrip {
  /// Keys of the input object (known ones too).
  Set<String> had = {};

  /// Keys of the input the model has no field for; written back as they were.
  Json unknown = {};

  /// Call from `fromJson` with the input and the keys the model knows.
  void capture(Json j, Set<String> known) {
    had = j.keys.toSet();
    unknown = {for (final e in j.entries) if (!known.contains(e.key)) e.key: deepCopy(e.value)};
  }

  /// Writes [key]; with [omit] only when the input had the key.
  void put(Json out, String key, Object? value, {bool omit = false}) {
    if (omit && !had.contains(key)) return;
    out[key] = value;
  }

  /// The unknown keys, last (a copy).
  void putUnknown(Json out) => out.addAll(deepCopy(unknown) as Json);
}

/// A stable sort (Dart's `List.sort` is not guaranteed to be stable, JavaScript's is).
List<T> stableSorted<T>(Iterable<T> items, num Function(T) rank) {
  final xs = [for (final (i, x) in items.indexed) (i, x, rank(x))];
  xs.sort((a, b) {
    final c = a.$3.compareTo(b.$3);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final x in xs) x.$2];
}
