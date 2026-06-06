import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/matter_device.dart';
import '../../domain/services/device_manager.dart';

/// Device Settings Screen
///
/// All per-device configuration lives here — rename, broker overrides, etc.
/// Accessible only via the detail screen to prevent accidental edits from the
/// dashboard.
class DeviceSettingsScreen extends ConsumerStatefulWidget {
  final MatterDevice device;

  const DeviceSettingsScreen({super.key, required this.device});

  @override
  ConsumerState<DeviceSettingsScreen> createState() =>
      _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends ConsumerState<DeviceSettingsScreen> {
  late final TextEditingController _nameController;

  /// True when the device has at least one relay — power restore only applies
  /// to output devices, not pure sensors.
  bool get _hasRelay => widget.device.capabilities
      .any((c) => c == 'relay' || c.startsWith('relay_'));

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.device.displayName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveAndPop() async {
    final trimmed = _nameController.text.trim();
    await ref
        .read(deviceManagerProvider.notifier)
        .renameDevice(widget.device.uniqueDeviceId, trimmed);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _setRestoreMode(PowerRestoreMode mode) async {
    await ref
        .read(deviceManagerProvider.notifier)
        .setPowerRestoreMode(widget.device.uniqueDeviceId, mode);
  }

  @override
  Widget build(BuildContext context) {
    // Watch live device so the power restore chip updates immediately after send.
    final device = ref
            .watch(deviceManagerProvider)
            .valueOrNull
            ?.firstWhere(
              (d) => d.uniqueDeviceId == widget.device.uniqueDeviceId,
              orElse: () => widget.device,
            ) ??
        widget.device;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Device Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: _saveAndPop,
            child: const Text(
              'Save',
              style: TextStyle(
                color: Color(0xFF00E5FF),
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Device identity ──────────────────────────────────────────
          _section('Identity'),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Display Name',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameController,
                  autofocus: false,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: widget.device.deviceName,
                    hintStyle: const TextStyle(color: Colors.white24),
                    helperText: 'Leave blank to use the auto-generated name',
                    helperStyle:
                        const TextStyle(color: Colors.white24, fontSize: 11),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.clear, size: 18,
                          color: Colors.white24),
                      tooltip: 'Revert to auto-generated name',
                      onPressed: () =>
                          setState(() => _nameController.clear()),
                    ),
                    enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white12)),
                    focusedBorder: const UnderlineInputBorder(
                        borderSide:
                            BorderSide(color: Color(0xFF00E5FF))),
                  ),
                ),
              ],
            ),
          ),

          // ── Power Restore ────────────────────────────────────────────
          if (_hasRelay) ...[
            const SizedBox(height: 24),
            _section('Power Restore'),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'What should this device do when power returns after an outage or restart?',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  _restoreOption(
                    current: device.powerRestoreMode,
                    value: PowerRestoreMode.off,
                    label: 'Always OFF',
                    description:
                        'Stays off — you switch it on manually. Safest choice.',
                    icon: Icons.power_off_rounded,
                  ),
                  _restoreOption(
                    current: device.powerRestoreMode,
                    value: PowerRestoreMode.restore,
                    label: 'Restore last state',
                    description:
                        'Returns to whatever it was before the outage.',
                    icon: Icons.history_rounded,
                  ),
                  _restoreOption(
                    current: device.powerRestoreMode,
                    value: PowerRestoreMode.on,
                    label: 'Always ON',
                    description:
                        'Turns on automatically — useful for essential devices.',
                    icon: Icons.power_rounded,
                  ),
                  if (device.status != DeviceStatus.online) ...[
                    const SizedBox(height: 10),
                    const Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 13, color: Colors.white38),
                        SizedBox(width: 6),
                        Text(
                          'Device is offline — setting will apply on reconnect.',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),

          // ── Read-only device info ────────────────────────────────────
          _section('Device Info'),
          _card(
            child: Column(
              children: [
                _infoRow('Device ID', widget.device.uniqueDeviceId),
                _infoRow(
                    'Firmware Name', widget.device.deviceName),
                _infoRow(
                    'Capabilities',
                    widget.device.capabilities.isEmpty
                        ? '—'
                        : widget.device.capabilities.join(', ')),
                _infoRow(
                    'Local IP',
                    widget.device.localIp?.isNotEmpty == true
                        ? widget.device.localIp!
                        : '—'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _restoreOption({
    required PowerRestoreMode current,
    required PowerRestoreMode value,
    required String label,
    required String description,
    required IconData icon,
  }) {
    final selected = current == value;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _setRestoreMode(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Radio indicator
            Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(top: 2, right: 12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? const Color(0xFF00E5FF)
                      : Colors.white24,
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF00E5FF),
                        ),
                      ),
                    )
                  : null,
            ),
            // Icon
            Icon(icon,
                size: 18,
                color:
                    selected ? const Color(0xFF00E5FF) : Colors.white38),
            const SizedBox(width: 10),
            // Text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      )),
                  const SizedBox(height: 2),
                  Text(description,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
      );

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: child,
      );

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 12)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12)),
            ),
          ],
        ),
      );
}
