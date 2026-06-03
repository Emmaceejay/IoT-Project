import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/mqtt_service.dart';
import '../screens/dashboard_screen.dart';
import '../screens/matter_pairing_screen.dart';
import '../screens/settings_screen.dart';

/// Root shell with a persistent bottom navigation bar.
/// Houses Dashboard, Pair Device, and Settings tabs.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // Auto-connect to the factory or previously saved broker on startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(mqttServiceProvider.notifier).connect();
    });
  }

  final List<Widget> _screens = const [
    DashboardScreen(),
    MatterPairingScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF0D1220),
        indicatorColor: const Color(0xFF00E5FF).withValues(alpha: 0.15),
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard, color: Color(0xFF00E5FF)),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_circle_outline),
            selectedIcon: Icon(Icons.add_circle, color: Color(0xFF00E5FF)),
            label: 'Add Device',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings, color: Color(0xFF00E5FF)),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
