import 'package:flutter/material.dart';
import '../../domain/models/smart_device.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/device_type_registry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Schema-Driven UI Builder
/// 
/// This widget is the core of the Universal Device Support strategy.
/// It reads a device's [capabilities] list and dynamically renders
/// the correct controls — no hardcoded UI per device type.
class SchemaDrivenUiBuilder extends ConsumerWidget {
  final SmartDevice device;

  const SchemaDrivenUiBuilder({super.key, required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = device.status == DeviceStatus.offline;
    final registry = ref.read(deviceTypeRegistryProvider);

    return AbsorbPointer(
      absorbing: isOffline,
      child: Opacity(
        opacity: isOffline ? 0.4 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...device.capabilities.map(
              (cap) => _buildCapabilityWidget(context, ref, cap, registry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapabilityWidget(
      BuildContext context, WidgetRef ref, String capability,
      DeviceTypeRegistry registry) {
    // All metadata (labels, icons, value ranges, telemetry/command keys) comes
    // from the registry. Adding a new device type requires no changes here.
    final capDef = registry.lookupCapability(capability);

    switch (capability) {
      // ── On/off relay gangs (1–4) — unified via capDef keys ───────────────
      case 'relay':
      case 'relay_2':
      case 'relay_3':
      case 'relay_4':
        if (capDef == null) break;
        final isOn = device.telemetry[capDef.telemetryKey] as bool? ?? false;
        return _CapabilityTile(
          icon: isOn ? capDef.icon : Icons.power_off,
          label: capDef.label,
          child: _RelaySwitch(
            serverValue: isOn,
            onChanged: (v) => ref
                .read(deviceManagerProvider.notifier)
                .sendCommand(device.uniqueDeviceId, {capDef.commandKey: v}),
          ),
        );

      // ── Continuous sliders (brightness, color_temp) ───────────────────────
      case 'brightness':
      case 'color_temp':
        if (capDef == null) break;
        final sliderVal =
            (device.telemetry[capDef.telemetryKey] as num?)?.toDouble() ??
                capDef.min ??
                0.0;
        final step = capDef.step ?? 1.0;
        final divisions = ((capDef.max! - capDef.min!) / step).round();
        return _CapabilityTile(
          icon: capDef.icon,
          label: '${capDef.label}  ${sliderVal.round()}${capDef.unit ?? ""}',
          child: _ValueSlider(
            serverValue: sliderVal,
            min: capDef.min!,
            max: capDef.max!,
            divisions: divisions,
            onChangeEnd: (v) => ref
                .read(deviceManagerProvider.notifier)
                .sendCommand(device.uniqueDeviceId, {capDef.commandKey: v.round()}),
          ),
        );

      // ── Temperature read-only ─────────────────────────────────────────────
      case 'temperature':
        final tempVal = device.telemetry[capDef?.telemetryKey ?? 'current_temp'] ?? '—';
        return _CapabilityTile(
          icon: capDef?.icon ?? Icons.thermostat,
          label: capDef?.label ?? 'Temperature',
          child: Text(
            '$tempVal ${capDef?.unit ?? "°C"}',
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
        );

      // ── Humidity read-only ────────────────────────────────────────────────
      case 'humidity':
        final humVal =
            (device.telemetry[capDef?.telemetryKey ?? 'humidity'] as num?)
                    ?.toStringAsFixed(1) ??
                '—';
        return _CapabilityTile(
          icon: capDef?.icon ?? Icons.water_drop_outlined,
          label: capDef?.label ?? 'Humidity',
          child: Text(
            '$humVal ${capDef?.unit ?? "%"}',
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
        );

      // ── Motion sensor ─────────────────────────────────────────────────────
      case 'motion':
        final motion =
            device.telemetry[capDef?.telemetryKey ?? 'motion'] as bool? ?? false;
        return _CapabilityTile(
          icon: motion
              ? (capDef?.icon ?? Icons.directions_run)
              : Icons.accessibility_new,
          label: capDef?.label ?? 'Motion',
          child: _StatusBadge(
            active: motion,
            activeLabel: 'Detected',
            inactiveLabel: 'Clear',
            activeColor: const Color(0xFF00E5FF),
            inactiveColor: Colors.white38,
          ),
        );

      // ── Contact sensor ────────────────────────────────────────────────────
      case 'contact':
        final closed =
            device.telemetry[capDef?.telemetryKey ?? 'contact'] as bool? ?? false;
        return _CapabilityTile(
          icon: closed ? Icons.lock : Icons.lock_open,
          label: capDef?.label ?? 'Contact',
          child: _StatusBadge(
            active: closed,
            activeLabel: 'Closed',
            inactiveLabel: 'Open',
            activeColor: Colors.greenAccent,
            inactiveColor: Colors.orangeAccent,
            activeBg: Colors.green.withValues(alpha: 0.15),
            inactiveBg: Colors.orange.withValues(alpha: 0.15),
          ),
        );

      // ── HVAC thermostat ───────────────────────────────────────────────────
      case 'hvac_mode':
        final target =
            (device.telemetry[capDef?.telemetryKey ?? 'target_temp'] as num?)
                    ?.toDouble() ??
                22.0;
        final step = capDef?.step ?? 0.5;
        final modeRaw = device.telemetry['mode'];
        final mode = modeRaw is String ? modeRaw : 'auto';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CapabilityTile(
              icon: mode == 'cool'
                  ? Icons.ac_unit
                  : mode == 'heat'
                      ? Icons.local_fire_department
                      : capDef?.icon ?? Icons.hvac,
              label:
                  '${capDef?.label ?? "HVAC"}  ${target.toStringAsFixed(1)}${capDef?.unit ?? "°C"}',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => ref
                        .read(deviceManagerProvider.notifier)
                        .sendCommand(device.uniqueDeviceId,
                            {capDef?.commandKey ?? 'target_temp': target - step}),
                  ),
                  Text(
                    '${target.toStringAsFixed(1)}°',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => ref
                        .read(deviceManagerProvider.notifier)
                        .sendCommand(device.uniqueDeviceId,
                            {capDef?.commandKey ?? 'target_temp': target + step}),
                  ),
                ],
              ),
            ),
            _HvacModeSelector(deviceId: device.uniqueDeviceId, currentMode: mode),
          ],
        );

      // ── RGB light ─────────────────────────────────────────────────────────
      case 'rgb':
        final r = (device.telemetry['red']   as num?)?.round() ?? 255;
        final g = (device.telemetry['green'] as num?)?.round() ?? 255;
        final b = (device.telemetry['blue']  as num?)?.round() ?? 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CapabilityTile(
              icon: capDef?.icon ?? Icons.palette_outlined,
              label: '${capDef?.label ?? "RGB"}  R:$r  G:$g  B:$b',
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color.fromARGB(255, r, g, b),
                  border: Border.all(color: Colors.white24),
                ),
              ),
            ),
            _RgbSlider(
              label: 'R', value: r.toDouble(), color: Colors.red.shade300,
              onChangeEnd: (v) => ref.read(deviceManagerProvider.notifier)
                  .sendCommand(device.uniqueDeviceId, {'red': v.round()}),
            ),
            _RgbSlider(
              label: 'G', value: g.toDouble(), color: Colors.green.shade300,
              onChangeEnd: (v) => ref.read(deviceManagerProvider.notifier)
                  .sendCommand(device.uniqueDeviceId, {'green': v.round()}),
            ),
            _RgbSlider(
              label: 'B', value: b.toDouble(), color: Colors.blue.shade300,
              onChangeEnd: (v) => ref.read(deviceManagerProvider.notifier)
                  .sendCommand(device.uniqueDeviceId, {'blue': v.round()}),
            ),
          ],
        );

      default:
        break;
    }

    // Unknown capability — graceful fallback so future firmware additions
    // don't crash the UI; they simply show a placeholder row.
    return _CapabilityTile(
      icon: Icons.device_unknown_outlined,
      label: capDef?.label ?? capability,
      child: const Text('Unsupported capability',
          style: TextStyle(color: Colors.grey, fontSize: 12)),
    );
  }
}

/// Switch that owns its own animation state so Riverpod rebuilds triggered by
/// the optimistic update never restart the slide animation mid-gesture.
///
/// Without this, the Switch's AnimationController receives two forward() calls
/// in the same frame (once from the gesture handler, once from didUpdateWidget
/// reacting to the Riverpod state change), causing a visible stutter.
class _RelaySwitch extends StatefulWidget {
  final bool serverValue;
  final ValueChanged<bool> onChanged;

  const _RelaySwitch({
    required this.serverValue,
    required this.onChanged,
  });

  @override
  State<_RelaySwitch> createState() => _RelaySwitchState();
}

class _RelaySwitchState extends State<_RelaySwitch> {
  late bool _local;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    _local = widget.serverValue;
  }

  @override
  void didUpdateWidget(_RelaySwitch old) {
    super.didUpdateWidget(old);
    // Accept the server value only when idle or when the server has caught up
    // with our local change. While _pending is true, we own the value.
    if (!_pending || widget.serverValue == _local) {
      _local = widget.serverValue;
      _pending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Switch.adaptive(
      value: _local,
      onChanged: (newVal) {
        setState(() {
          _local = newVal;
          _pending = true;
        });
        widget.onChanged(newVal);
      },
    );
  }
}

/// Slider that tracks a local value during drag and syncs to [serverValue] when idle.
/// Prevents the snap-back artifact caused by a StatelessWidget re-reading the
/// server-confirmed value on every frame while the user is still dragging.
class _ValueSlider extends StatefulWidget {
  final double serverValue;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChangeEnd;

  const _ValueSlider({
    required this.serverValue,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChangeEnd,
  });

  @override
  State<_ValueSlider> createState() => _ValueSliderState();
}

class _ValueSliderState extends State<_ValueSlider> {
  late double _local;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _local = widget.serverValue;
  }

  @override
  void didUpdateWidget(_ValueSlider old) {
    super.didUpdateWidget(old);
    if (!_dragging) _local = widget.serverValue;
  }

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: _local,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      onChanged: (v) => setState(() {
        _local = v;
        _dragging = true;
      }),
      onChangeEnd: (v) {
        setState(() => _dragging = false);
        widget.onChangeEnd(v);
      },
    );
  }
}

/// Mode chip row for the HVAC control capability (cool / heat / auto / off).
class _HvacModeSelector extends ConsumerWidget {
  final String deviceId;
  final String currentMode;

  const _HvacModeSelector({required this.deviceId, required this.currentMode});

  static const _modes = <String, IconData>{
    'cool': Icons.ac_unit,
    'heat': Icons.local_fire_department,
    'auto': Icons.autorenew,
    'off':  Icons.power_settings_new,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(left: 32, bottom: 6),
      child: Row(
        children: _modes.entries.map((entry) {
          final isActive = currentMode == entry.key;
          final label = '${entry.key[0].toUpperCase()}${entry.key.substring(1)}';
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => ref
                  .read(deviceManagerProvider.notifier)
                  .sendCommand(deviceId, {'mode': entry.key}),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0xFF00E5FF).withValues(alpha: 0.2)
                      : Colors.white10,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isActive ? const Color(0xFF00E5FF) : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(entry.value, size: 14,
                        color: isActive ? const Color(0xFF00E5FF) : Colors.white38),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        color: isActive ? const Color(0xFF00E5FF) : Colors.white38,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Compact slider row for one RGB channel, indented under the RGB header tile.
class _RgbSlider extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  final ValueChanged<double> onChangeEnd;

  const _RgbSlider({
    required this.label,
    required this.value,
    required this.color,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 32, right: 4),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: 0,
              max: 255,
              divisions: 255,
              activeColor: color,
              inactiveColor: color.withValues(alpha: 0.2),
              onChangeEnd: onChangeEnd,
              onChanged: (_) {},
            ),
          ),
          SizedBox(
            width: 28,
            child: Text('${value.round()}',
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

/// Reusable badge for binary sensor states (motion detected/clear, contact closed/open).
/// Consolidates the duplicated container+text pattern from the original builder.
class _StatusBadge extends StatelessWidget {
  final bool active;
  final String activeLabel;
  final String inactiveLabel;
  final Color activeColor;
  final Color inactiveColor;
  final Color? activeBg;
  final Color? inactiveBg;

  const _StatusBadge({
    required this.active,
    required this.activeLabel,
    required this.inactiveLabel,
    required this.activeColor,
    required this.inactiveColor,
    this.activeBg,
    this.inactiveBg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? (activeBg ?? activeColor.withValues(alpha: 0.15))
            : (inactiveBg ?? Colors.white12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        active ? activeLabel : inactiveLabel,
        style: TextStyle(
          color: active ? activeColor : inactiveColor,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
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
