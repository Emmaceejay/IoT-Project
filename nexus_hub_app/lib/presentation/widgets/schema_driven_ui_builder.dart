import 'package:flutter/material.dart';
import '../../domain/models/matter_device.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/device_manager.dart';

/// Schema-Driven UI Builder
/// 
/// This widget is the core of the Universal Device Support strategy.
/// It reads a device's [capabilities] list and dynamically renders
/// the correct controls — no hardcoded UI per device type.
class SchemaDrivenUiBuilder extends ConsumerWidget {
  final MatterDevice device;

  const SchemaDrivenUiBuilder({super.key, required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = device.status == DeviceStatus.offline;

    return AbsorbPointer(
      absorbing: isOffline, // Disable all controls if device is offline
      child: Opacity(
        opacity: isOffline ? 0.4 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Render a control widget for each declared capability
            ...device.capabilities.map(
              (capability) => _buildCapabilityWidget(context, ref, capability),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapabilityWidget(
      BuildContext context, WidgetRef ref, String capability) {
    switch (capability) {
      // ── Simple on/off relay ──────────────────────────────────────────
      case 'relay':
        final isOn = device.telemetry['power'] as bool? ?? false;
        return _CapabilityTile(
          icon: isOn ? Icons.power : Icons.power_off,
          label: 'Power',
          child: Switch.adaptive(
            value: isOn,
            onChanged: (_) => ref
                .read(deviceManagerProvider.notifier)
                .sendCommand(device.uniqueDeviceId, {'power': !isOn}),
          ),
        );

      // ── Brightness dimmer ────────────────────────────────────────────
      case 'dimmer':
        final brightness = (device.telemetry['brightness'] as num?)?.toDouble() ?? 100.0;
        return _CapabilityTile(
          icon: Icons.brightness_medium,
          label: 'Brightness  ${brightness.round()}%',
          child: Slider(
            value: brightness,
            min: 0,
            max: 100,
            divisions: 20,
            onChangeEnd: (v) => ref
                .read(deviceManagerProvider.notifier)
                .sendCommand(device.uniqueDeviceId, {'brightness': v.round()}),
            onChanged: (_) {}, // Handled by onChangeEnd for performance
          ),
        );

      // ── Color temperature ────────────────────────────────────────────
      case 'color_temperature':
        final kelvin = (device.telemetry['color_temp'] as num?)?.toDouble() ?? 4000;
        return _CapabilityTile(
          icon: Icons.wb_sunny_outlined,
          label: 'Color Temp  ${kelvin.round()}K',
          child: Slider(
            value: kelvin,
            min: 2000,
            max: 6500,
            divisions: 45,
            onChangeEnd: (v) => ref
                .read(deviceManagerProvider.notifier)
                .sendCommand(device.uniqueDeviceId, {'color_temp': v.round()}),
            onChanged: (_) {},
          ),
        );

      // ── Temperature sensor (read-only) ───────────────────────────────
      case 'temperature_sensor':
        final temp = device.telemetry['current_temp'] ?? '—';
        return _CapabilityTile(
          icon: Icons.thermostat,
          label: 'Current Temp',
          child: Text(
            '$temp °C',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
        );

      // ── HVAC control ─────────────────────────────────────────────────
      case 'hvac_control':
        final target = (device.telemetry['target_temp'] as num?)?.toDouble() ?? 22.0;
        final mode = device.telemetry['mode'] as String? ?? 'cool';
        return _CapabilityTile(
          icon: mode == 'cool' ? Icons.ac_unit : Icons.local_fire_department,
          label: 'Target  ${target.round()}°C',
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => ref
                    .read(deviceManagerProvider.notifier)
                    .sendCommand(device.uniqueDeviceId, {'target_temp': target - 0.5}),
              ),
              Text(
                '${target.toStringAsFixed(1)}°',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => ref
                    .read(deviceManagerProvider.notifier)
                    .sendCommand(device.uniqueDeviceId, {'target_temp': target + 0.5}),
              ),
            ],
          ),
        );

      // ── Unknown capability — future-proofed graceful fallback ────────
      default:
        return _CapabilityTile(
          icon: Icons.device_unknown_outlined,
          label: capability,
          child: const Text('Unsupported capability',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        );
    }
  }
}

/// A consistent row tile used for every capability control.
class _CapabilityTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;

  const _CapabilityTile({
    required this.icon,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF00E5FF)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ),
          child,
        ],
      ),
    );
  }
}
