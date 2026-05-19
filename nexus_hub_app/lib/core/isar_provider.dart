import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';

/// Global Isar instance provider.
///
/// MUST be overridden in main() before the app launches:
///   ProviderScope(
///     overrides: [isarProvider.overrideWithValue(isar)],
///     child: const NexusHubApp(),
///   )
///
/// In tests, override with a temp-directory Isar or override
/// deviceRepositoryProvider directly to bypass Isar entirely.
final isarProvider = Provider<Isar>((ref) {
  throw UnimplementedError(
    'isarProvider must be overridden in main() with an initialized Isar instance.',
  );
});
