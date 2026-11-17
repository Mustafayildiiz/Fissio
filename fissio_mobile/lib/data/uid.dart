import 'dart:math';

final _rng = Random.secure();

/// Kalıcı istemci kimliği (`client_uid`): sunucu regex'i `[A-Za-z0-9._:-]{1,64}` ile uyumlu.
String newClientUid([String prefix = 'm']) {
  final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$hex';
}
