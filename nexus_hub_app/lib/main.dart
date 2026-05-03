import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'presentation/widgets/app_shell.dart';

void main() {
  runApp(
    // ProviderScope is the Riverpod root — wraps the entire app
    const ProviderScope(
      child: NexusHubApp(),
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
        seedColor: const Color(0xFF00E5FF), // Cyan accent
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF0A0E1A),
      cardTheme: CardTheme(
        color: const Color(0xFF121826),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      fontFamily: 'Roboto',
    );
  }
}
