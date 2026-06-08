import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/matter_device.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/ota_service.dart';
import 'device_settings_screen.dart';

/// Device Detail Screen
///
/// Full-page view for a single device showing:
/// – Live telemetry
/// – Manifest-driven OTA firmware update controls
class DeviceDetailScreen extends ConsumerStatefulWidget {
  final MatterDevice device;
  const DeviceDetailScreen({super.key, required this.device});

  @override
  ConsumerState<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  bool _otaTriggered = false;

  @override
  Widget build(BuildContext context) {
    // Watch the live device record so status, telemetry, and name update
    // reactively without depending on the navigation-time snapshot.
    final device = ref.watch(deviceManagerProvider).valueOrNull
            ?.firstWhere(
              (d) => d.uniqueDeviceId == widget.device.uniqueDeviceId,
              orElse: () => widget.device,
            ) ??
        widget.device;

    final otaService = ref.watch(otaServiceProvider);
    final isOnline = device.status == DeviceStatus.online;
    final manifestAsync = ref.watch(manifestProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(device.displayName,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white54),
            tooltip: 'Device Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DeviceSettingsScreen(device: device),
              ),
            ),
          ),
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
          _infoCard(isOnline, device),
          const SizedBox(height: 20),

          // ── Telemetry Preview ─────────────────────────────────────
          _section('Live Telemetry'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: device.telemetry.isEmpty
                  ? const Text('No telemetry yet.',
                      style: TextStyle(color: Colors.white38))
                  : Column(
                      children: device.telemetry.entries
                          .map((e) => _telemetryRow(e.key, e.value.toString()))
                          .toList(),
                    ),
            ),
          ),
          const SizedBox(height: 20),

          // ── OTA Firmware Update ───────────────────────────────────
          _section('Firmware Update'),
          _buildOtaSection(device, isOnline, manifestAsync, otaService),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // ── OTA section ────────────────────────────────────────────────────────────

  Widget _buildOtaSection(
    MatterDevice device,
    bool isOnline,
    AsyncValue<FirmwareManifest?> manifestAsync,
    OtaOrchestratorService otaService,
  ) {
    // Once update is triggered show the progress view exclusively.
    if (_otaTriggered) {
      return StreamBuilder<OtaUpdateState>(
        stream: otaService.watchUpdate(device.uniqueDeviceId),
        builder: (context, snap) {
          final state =
              snap.data ?? OtaUpdateState.idle(widget.device.uniqueDeviceId);
          return _OtaProgressWidget(state: state);
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FirmwareInfoRow(
          deviceType: device.deviceType,
          currentVersion: device.firmwareVersion,
        ),
        const SizedBox(height: 12),
        manifestAsync.when(
          data: (manifest) =>
              _manifestDataWidget(manifest, device, isOnline, otaService),
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(color: Color(0xFF00E5FF)),
            ),
          ),
          error: (e, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _alertTile(
                icon: Icons.error_outline,
                color: Colors.redAccent,
                message: 'Could not fetch manifest: $e',
              ),
              const SizedBox(height: 8),
              _checkButton(label: 'Retry'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _manifestDataWidget(
    FirmwareManifest? manifest,
    MatterDevice device,
    bool isOnline,
    OtaOrchestratorService otaService,
  ) {
    // Null means not yet fetched — show the initial check button.
    if (manifest == null) return _checkButton();

    // Old firmware that doesn't report device_type yet.
    if (device.deviceType.isEmpty) {
      return _alertTile(
        icon: Icons.info_outline,
        color: Colors.white38,
        message:
            'This device is running older firmware that does not report a '
            'device type. Flash the latest firmware via USB to enable OTA updates.',
      );
    }

    final entry = manifest.entryFor(device.deviceType);
    if (entry == null) {
      return _alertTile(
        icon: Icons.info_outline,
        color: Colors.white38,
        message:
            'Device type "${device.deviceType}" is not listed in the current '
            'manifest. Update firmware_manifest.json in the repo.',
      );
    }

    final isUpToDate = device.firmwareVersion.isNotEmpty &&
        device.firmwareVersion == manifest.version;

    if (isUpToDate) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _alertTile(
            icon: Icons.check_circle_outline,
            color: Colors.greenAccent,
            message: 'Up to date — v${manifest.version}',
          ),
          const SizedBox(height: 8),
          _checkButton(label: 'Check again', muted: true),
        ],
      );
    }

    // Update available.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _updateAvailableTile(manifest: manifest, currentVersion: device.firmwareVersion),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: isOnline && entry.url.isNotEmpty
                ? const Color(0xFF00E5FF)
                : const Color(0xFF1E2A3A),
            foregroundColor:
                isOnline && entry.url.isNotEmpty ? Colors.black : Colors.white38,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: isOnline && entry.url.isNotEmpty
              ? () async {
                  setState(() => _otaTriggered = true);
                  await otaService.triggerUpdate(
                    deviceId: device.uniqueDeviceId,
                    firmwareUrl: entry.url,
                    expectedHash: entry.hash,
                  );
                }
              : null,
          icon: const Icon(Icons.system_update_alt),
          label: Text(
            !isOnline
                ? 'Device Offline'
                : entry.url.isEmpty
                    ? 'No binary uploaded yet'
                    : 'Update to v${manifest.version}',
          ),
        ),
      ],
    );
  }

  Widget _checkButton({String label = 'Check for Updates', bool muted = false}) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor:
            muted ? Colors.white38 : const Color(0xFF00E5FF),
        side: BorderSide(
          color: muted
              ? Colors.white12
              : const Color(0xFF00E5FF),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: () => ref.read(manifestProvider.notifier).fetch(),
      icon: Icon(
        Icons.cloud_download_outlined,
        size: muted ? 16 : 20,
      ),
      label: Text(label, style: TextStyle(fontSize: muted ? 13 : 14)),
    );
  }

  Widget _alertTile({
    required IconData icon,
    required Color color,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _updateAvailableTile({
    required FirmwareManifest manifest,
    required String currentVersion,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: Colors.orangeAccent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_alt,
                  color: Colors.orangeAccent, size: 16),
              const SizedBox(width: 8),
              Text(
                'Update available: v${manifest.version}',
                style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (currentVersion.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Installed: v$currentVersion',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
          if (manifest.releaseDate.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              'Released: ${manifest.releaseDate}',
              style: const TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ],
          if (manifest.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              manifest.notes,
              style: const TextStyle(
                  color: Colors.white54, fontSize: 12, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  // ── Misc helpers ───────────────────────────────────────────────────────────

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF121826),
        title: const Text('Remove Device?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Remove "${widget.device.displayName}"? It can be re-added by re-pairing.',
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

  Widget _infoCard(bool isOnline, MatterDevice device) {
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
            _infoRow('Device ID', device.uniqueDeviceId),
            _infoRow('Capabilities', device.capabilities.join(', ')),
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
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 12)),
            ),
            Expanded(
              child: Text(value,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12)),
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
                style:
                    const TextStyle(color: Colors.white54, fontSize: 13)),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ],
        ),
      );

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16)),
      );
}

// ── Sub-widgets ────────────────────────────────────────────────────────────────

class _FirmwareInfoRow extends StatelessWidget {
  final String deviceType;
  final String currentVersion;

  const _FirmwareInfoRow({
    required this.deviceType,
    required this.currentVersion,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.memory_outlined, color: Colors.white38, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  deviceType.isNotEmpty ? deviceType : 'Unknown model',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                Text(
                  currentVersion.isNotEmpty
                      ? 'Firmware v$currentVersion'
                      : 'Version unknown (older firmware)',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OtaProgressWidget extends StatelessWidget {
  final OtaUpdateState state;
  const _OtaProgressWidget({required this.state});

  @override
  Widget build(BuildContext context) {
    final isDone = state.status == OtaStatus.complete;
    final isFailed = state.status == OtaStatus.failed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isDone
                      ? Icons.check_circle
                      : isFailed
                          ? Icons.error_outline
                          : Icons.downloading,
                  color: isDone
                      ? Colors.greenAccent
                      : isFailed
                          ? Colors.redAccent
                          : const Color(0xFF00E5FF),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isDone
                        ? 'Update Complete!'
                        : isFailed
                            ? 'Update Failed'
                            : 'Flashing... ${state.progressPercent}%',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (!isFailed) ...[
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
            ],
            if (!isDone && !isFailed) ...[
              const SizedBox(height: 8),
              const Text(
                'Do not close the app. Device will reboot automatically.',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
            if (isFailed && state.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                state.errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
