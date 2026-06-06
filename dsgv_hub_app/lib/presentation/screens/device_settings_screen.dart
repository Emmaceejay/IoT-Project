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

  @override
  Widget build(BuildContext context) {
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
