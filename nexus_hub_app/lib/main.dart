import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import 'core/isar_provider.dart';
import 'data/models/isar_device.dart';
import 'presentation/widgets/app_shell.dart';

/// App entry point.
///
/// Performs one-time async initialisation before the widget tree is mounted:
///   1. Isar database — offline-first device cache (architecture whitepaper §4)
///
/// The [isarProvider] override makes the singleton available to every Riverpod
/// provider that depends on it without manual passing through constructors.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Initialise Isar (offline-first device persistence) ────────────────────
  final dir = await getApplicationDocumentsDirectory();
  final isar = await Isar.open(
    [IsarDeviceSchema],
    directory: dir.path,
    inspector: false, // Disable Isar Inspector in release builds
  );

  runApp(
    ProviderScope(
      overrides: [
        isarProvider.overrideWithValue(isar),
      ],
      child: const NexusHubApp(),
    ),
  );
}

class NexusHubApp extends StatelessWidget {
  const NexusHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus Hub',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const AppShell(),
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00E5FF),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF0A0E1A),
      cardTheme: const CardThemeData(
        color: Color(0xFF121826),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: Color(0x0FFFFFFF)),
        ),
      ),
      fontFamily: 'Roboto',
    );
  }
}
