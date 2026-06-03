import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/mqtt_service.dart';
import '../screens/dashboard_screen.dart';
import '../screens/device_pairing_screen.dart';
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

    // Run startup network tasks after the first frame is rendered so the
    // widget tree is fully built before any async state changes arrive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 1. Connect to the MQTT broker (cloud remote control + telemetry).
      //    This is the primary discovery path — devices announce themselves
      //    via the "devices/+/announce" topic when they connect.
      ref.read(mqttServiceProvider.notifier).connect();

      // 2. Scan the local LAN for devices via mDNS (_dsgv._tcp.local).
      //    This fills in localIp for devices on the same Wi-Fi, enabling
      //    direct HTTP commands (<10 ms) before their MQTT announce arrives.
      //    Runs concurrently with MQTT — both paths feed into handleAnnounce.
      ref.read(deviceManagerProvider.notifier).discoverLocalDevices();
    });
  }

  final List<Widget> _screens = const [
    DashboardScreen(),
    DevicePairingScreen(),
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
