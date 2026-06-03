import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/iot_device.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/ota_service.dart';

/// Device Detail Screen
///
/// Full-page view for a single device showing:
/// – Live telemetry
/// – OTA firmware update controls with progress
class DeviceDetailScreen extends ConsumerStatefulWidget {
  final IoTDevice device;
  const DeviceDetailScreen({super.key, required this.device});

  @override
  ConsumerState<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  bool _otaTriggered = false;

  @override
  Widget build(BuildContext context) {
    final otaService = ref.watch(otaServiceProvider);
    final isOnline = widget.device.status == DeviceStatus.online;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(widget.device.deviceName,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Remove Device',
            onPressed: _confirmAndDelete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Device Info Card ──────────────────────────────────────
          _infoCard(isOnline),

          const SizedBox(height: 20),

          // ── Telemetry Preview ─────────────────────────────────────
          _section('Live Telemetry'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: widget.device.telemetry.isEmpty
                  ? const Text('No telemetry yet.',
                      style: TextStyle(color: Colors.white38))
                  : Column(
                      children: widget.device.telemetry.entries
                          .map((e) => _telemetryRow(e.key, e.value.toString()))
                          .toList(),
                    ),
            ),
          ),

          const SizedBox(height: 20),

          // ── OTA Firmware Update ───────────────────────────────────
          _section('Firmware Update'),
          if (!_otaTriggered)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E2A3A),
                foregroundColor: const Color(0xFF00E5FF),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: isOnline
                  ? () async {
                      // TODO(production): Replace with a real firmware manifest fetch.
                      // The URL must be a signed HTTPS link to the .bin file,
                      // and the hash must be the SHA-256 hex digest of that binary.
                      // Never hardcode these values in production builds.
                      const firmwareUrl = String.fromEnvironment('OTA_FIRMWARE_URL');
                      const expectedHash = String.fromEnvironment('OTA_FIRMWARE_HASH');
                      assert(firmwareUrl.isNotEmpty,
                          'Set OTA_FIRMWARE_URL via --dart-define=OTA_FIRMWARE_URL=https://...');
                      assert(expectedHash.isNotEmpty,
                          'Set OTA_FIRMWARE_HASH via --dart-define=OTA_FIRMWARE_HASH=sha256...');
                      setState(() => _otaTriggered = true);
                      await otaService.triggerUpdate(
                        deviceId: widget.device.uniqueDeviceId,
                        firmwareUrl: firmwareUrl,
                        expectedHash: expectedHash,
                      );
                    }
                  : null,
              icon: const Icon(Icons.system_update_alt),
              label: const Text('Push Firmware Update'),
            )
          else
            StreamBuilder<OtaUpdateState>(
              stream: otaService.watchUpdate(widget.device.uniqueDeviceId),
              builder: (context, snap) {
                final state = snap.data ?? OtaUpdateState.idle(widget.device.uniqueDeviceId);
                return _OtaProgressWidget(state: state);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF121826),
        title: const Text('Remove Device?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Remove "${widget.device.deviceName}"? It can be re-added by re-pairing.',
          style: const TextStyle(
              color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final navigator = Navigator.of(context);
    await ref
        .read(deviceManagerProvider.notifier)
        .removeDevice(widget.device.uniqueDeviceId);
    if (!mounted) return;
    navigator.pop();
  }

  Widget _infoCard(bool isOnline) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isOnline ? const Color(0xFF00E5FF) : Colors.grey,
                    boxShadow: isOnline
                        ? [const BoxShadow(
                            color: Color(0xFF00E5FF), blurRadius: 8)]
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  isOnline ? 'Online' : 'Offline',
                  style: TextStyle(
                    color: isOnline ? const Color(0xFF00E5FF) : Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _infoRow('Device ID', widget.device.uniqueDeviceId),
            _infoRow('Capabilities', widget.device.capabilities.join(', ')),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _telemetryRow(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(key.replaceAll('_', ' '),
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
            Text(value,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      );

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
      );
}

class _OtaProgressWidget extends StatelessWidget {
  final OtaUpdateState state;
  const _OtaProgressWidget({required this.state});

  @override
  Widget build(BuildContext context) {
    final isDone = state.status == OtaStatus.complete;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isDone ? Icons.check_circle : Icons.downloading,
                  color: isDone ? Colors.greenAccent : const Color(0xFF00E5FF),
                ),
                const SizedBox(width: 8),
                Text(
                  isDone
                      ? 'Update Complete!'
                      : 'Flashing... ${state.progressPercent}%',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: state.progressPercent / 100.0,
                backgroundColor: const Color(0xFF1E2A3A),
                color: isDone ? Colors.greenAccent : const Color(0xFF00E5FF),
                minHeight: 8,
              ),
            ),
            if (!isDone) ...[
              const SizedBox(height: 8),
              const Text(
                'Do not close the app. Device will reboot automatically.',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
