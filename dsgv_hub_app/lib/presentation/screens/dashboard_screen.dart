import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/matter_device.dart';
import '../../domain/services/device_manager.dart';
import '../widgets/device_card.dart';
import 'matter_pairing_screen.dart';

/// The Main Dashboard — the app's home screen.
///
/// Watches [deviceManagerProvider] and reactively rebuilds
/// as devices come online, go offline, or update their telemetry.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deviceState = ref.watch(deviceManagerProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DSGV Hub',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Smart Device Dashboard',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
        actions: [
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white54),
            onPressed: () => ref.read(deviceManagerProvider.notifier).refresh(),
          ),
          // Matter QR Pair button
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF00E5FF)),
            tooltip: 'Pair New Device',
            onPressed: () => _launchMatterPairing(context),
          ),
        ],
      ),
      body: deviceState.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF00E5FF)),
        ),
        error: (err, _) => Center(
          child: Text('Error loading devices: $err',
              style: const TextStyle(color: Colors.redAccent)),
        ),
        data: (devices) => _buildDeviceList(context, ref, devices),
      ),
    );
  }

  Widget _buildDeviceList(
      BuildContext context, WidgetRef ref, List<MatterDevice> devices) {
    if (devices.isEmpty) {
      return const Center(
        child: Text(
          'No devices found.\nTap the QR icon to pair your first device.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38),
        ),
      );
    }

    // Separate online vs. offline for better UX
    final online = devices.where((d) => d.status == DeviceStatus.online).toList();
    final offline = devices.where((d) => d.status != DeviceStatus.online).toList();

    return RefreshIndicator(
      color: const Color(0xFF00E5FF),
      onRefresh: () => ref.read(deviceManagerProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          // ── Summary Stats row ──────────────────────────────────────
          _SummaryRow(total: devices.length, online: online.length),
          const SizedBox(height: 20),

          // ── Online Devices ─────────────────────────────────────────
          if (online.isNotEmpty) ...[
            _SectionHeader(
              label: 'Online',
              count: online.length,
              color: const Color(0xFF00E5FF),
            ),
            ...online.map((d) => DeviceCard(device: d)),
            const SizedBox(height: 16),
          ],

          // ── Offline Devices ────────────────────────────────────────
          if (offline.isNotEmpty) ...[
            _SectionHeader(
              label: 'Offline',
              count: offline.length,
              color: Colors.grey,
            ),
            ...offline.map((d) => DeviceCard(device: d)),
          ],
        ],
      ),
    );
  }

  void _launchMatterPairing(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MatterPairingScreen()),
    );
  }
}

/// Summary stats row at the top of the dashboard.
class _SummaryRow extends StatelessWidget {
  final int total;
  final int online;

  const _SummaryRow({required this.total, required this.online});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StatCard(label: 'Total Devices', value: total.toString()),
        const SizedBox(width: 12),
        _StatCard(
          label: 'Online',
          value: online.toString(),
          color: const Color(0xFF00E5FF),
        ),
        const SizedBox(width: 12),
        _StatCard(
          label: 'Offline',
          value: (total - online).toString(),
          color: Colors.grey,
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(label,
                style:
                    const TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// A labelled section divider.
class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _SectionHeader(
      {required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$label ($count)',
            style: TextStyle(
                color: color, fontWeight: FontWeight.w600, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
