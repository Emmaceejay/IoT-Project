import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/mqtt_service.dart';
import '../../domain/services/schedule_service.dart';
import '../screens/dashboard_screen.dart';
import '../screens/groups_screen.dart';
import '../screens/settings_screen.dart';

/// Root shell with a 3-tab bottom navigation bar: Dashboard, Groups, and
/// Settings. Device pairing is accessed via the "+" button on the dashboard —
/// not via a persistent tab — so the camera never opens unexpectedly.
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(mqttServiceProvider.notifier).connect();
      ref.read(scheduleServiceProvider); // warm-start evaluation timer
    });
  }

  final List<Widget> _screens = const [
    DashboardScreen(),
    GroupsScreen(),
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
            icon: Icon(Icons.group_work_outlined),
            selectedIcon: Icon(Icons.group_work, color: Color(0xFF00E5FF)),
            label: 'Groups',
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
