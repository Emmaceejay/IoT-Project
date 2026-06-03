import 'package:flutter/material.dart';
import '../../domain/models/iot_device.dart';
import '../widgets/schema_driven_ui_builder.dart';
import '../screens/device_detail_screen.dart';

/// Expandable card representing a single IoT device on the Dashboard.
class DeviceCard extends StatefulWidget {
  final IoTDevice device;

  const DeviceCard({super.key, required this.device});

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isOnline = widget.device.status == DeviceStatus.online;
    final statusColor = isOnline ? const Color(0xFF00E5FF) : Colors.grey;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _expanded = !_expanded),
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
              // ── Device Header ────────────────────────────────────────
              Row(
                children: [
                  // Status indicator dot
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusColor,
                      boxShadow: isOnline
                          ? [BoxShadow(color: statusColor.withValues(alpha: 0.5), blurRadius: 8)]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.device.deviceName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isOnline ? 'Online' : 'Offline',
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Capability chips
                  Wrap(
                    spacing: 4,
                    children: widget.device.capabilities
                        .take(2)
                        .map(
                          (c) => Chip(
                            label: Text(c.replaceAll('_', ' '),
                                style: const TextStyle(fontSize: 10, color: Colors.white70)),
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFF1E2A3A),
                            side: BorderSide.none,
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white38,
                  ),
                ],
              ),

              // ── Expanded Controls ────────────────────────────────────
              if (_expanded) ...[
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
