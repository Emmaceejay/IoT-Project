import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:objectbox/objectbox.dart';

/// Global ObjectBox [Store] provider.
///
/// MUST be overridden in main() before the app launches:
///   ProviderScope(
///     overrides: [objectboxStoreProvider.overrideWithValue(store)],
///     child: const DSGVHubApp(),
///   )
///
/// In tests, override [deviceRepositoryProvider] directly with a stub to
/// bypass the store entirely — no ObjectBox initialisation needed in tests.
final objectboxStoreProvider = Provider<Store>((ref) {
  throw UnimplementedError(
    'objectboxStoreProvider must be overridden in main() with an initialized Store.',
  );
});
