import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/matter_device.dart';
import '../../domain/services/device_manager.dart';
import '../widgets/schema_driven_ui_builder.dart';
import '../screens/device_detail_screen.dart';

/// Expandable card representing a single IoT device on the Dashboard.
///
/// Relay-only devices (1–4 gang switches) render their toggle(s) directly
/// inline — no expand step needed for a simple on/off action.
/// Devices with complex controls (dimmer, RGB, CCT, thermostat) keep the
/// tap-to-expand pattern so the card stays compact when collapsed.
class DeviceCard extends ConsumerStatefulWidget {
  final MatterDevice device;

  const DeviceCard({super.key, required this.device});

  @override
  ConsumerState<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<DeviceCard> {
  bool _expanded = false;

  // Pending toggle values prevent Riverpod optimistic updates from restarting
  // the Switch slide animation mid-gesture (same fix as _RelaySwitch /
  // _ValueSlider in schema_driven_ui_builder.dart).
  final Map<String, bool> _pendingToggles = {};

  bool _switchValue(String key) =>
      _pendingToggles.containsKey(key)
          ? _pendingToggles[key]!
          : (widget.device.telemetry[key] as bool? ?? false);

  @override
  void didUpdateWidget(DeviceCard old) {
    super.didUpdateWidget(old);
    // Clear a pending value once the server state has caught up.
    _pendingToggles.removeWhere(
        (key, local) => (widget.device.telemetry[key] as bool? ?? false) == local);
  }

  /// True when every capability is a relay gang — simple on/off device.
  bool get _isRelayOnly =>
      widget.device.capabilities.isNotEmpty &&
      widget.device.capabilities.every((c) => c.startsWith('relay'));

  // ── Inline relay toggles (relay-only devices) ──────────────────────────────

  Widget _buildInlineToggles() {
    final isOnline = widget.device.status == DeviceStatus.online;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: widget.device.capabilities.map((cap) {
        final telemetryKey = switch (cap) {
          'relay'   => 'power',
          'relay_2' => 'power_2',
          'relay_3' => 'power_3',
          _         => 'power_4',
        };
        final gangLabel = switch (cap) {
          'relay_2' => '2',
          'relay_3' => '3',
          'relay_4' => '4',
          _         => '',
        };

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (gangLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(gangLabel,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11)),
              ),
            Switch.adaptive(
              value: _switchValue(telemetryKey),
              onChanged: isOnline
                  ? (newVal) {
                      setState(() => _pendingToggles[telemetryKey] = newVal);
                      ref
                          .read(deviceManagerProvider.notifier)
                          .sendCommand(widget.device.uniqueDeviceId,
                              {telemetryKey: newVal});
                    }
                  : null,
            ),
          ],
        );
      }).toList(),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isOnline = widget.device.status == DeviceStatus.online;
    final statusColor =
        isOnline ? const Color(0xFF00E5FF) : Colors.grey;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        // Relay-only cards are not tappable for expand (no expand exists).
        onTap: _isRelayOnly
            ? null
            : () => setState(() => _expanded = !_expanded),
        onLongPress: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DeviceDetailScreen(device: widget.device),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row ───────────────────────────────────────────
              Row(
                children: [
                  // Status dot
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusColor,
                      boxShadow: isOnline
                          ? [
                              BoxShadow(
                                  color:
                                      statusColor.withValues(alpha: 0.5),
                                  blurRadius: 8)
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Name + status
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.device.displayName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isOnline ? 'Online' : 'Offline',
                          style: TextStyle(
                              color: statusColor, fontSize: 12),
                        ),
                      ],
                    ),
                  ),

                  // Right side: inline toggles OR capability chips + expand
                  if (_isRelayOnly) ...[
                    AbsorbPointer(
                      absorbing: !isOnline,
                      child: Opacity(
                        opacity: isOnline ? 1.0 : 0.4,
                        child: _buildInlineToggles(),
                      ),
                    ),
                  ] else ...[
                    Wrap(
                      spacing: 4,
                      children: widget.device.capabilities
                          .take(2)
                          .map((c) => Chip(
                                label: Text(
                                    c.replaceAll('_', ' '),
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white70)),
                                padding: EdgeInsets.zero,
                                backgroundColor:
                                    const Color(0xFF1E2A3A),
                                side: BorderSide.none,
                              ))
                          .toList(),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: Colors.white38,
                    ),
                  ],
                ],
              ),

              // ── Expanded controls (complex devices only) ─────────────
              if (!_isRelayOnly && _expanded) ...[
                const Divider(color: Colors.white12, height: 24),
                SchemaDrivenUiBuilder(device: widget.device),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
