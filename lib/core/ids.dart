import 'dart:math';

final _random = Random.secure();

/// Random 96-bit id with a time prefix, e.g. `m3k9x2-1f8e2a9c3b`.
///
/// Used for idempotency keys and locally created records. Not a UUID, but the
/// collision chance is negligible for these purposes.
String randomId() {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = List.generate(
    3,
    (_) => _random.nextInt(1 << 32).toRadixString(36),
  ).join();
  return '$time-$rand';
}
