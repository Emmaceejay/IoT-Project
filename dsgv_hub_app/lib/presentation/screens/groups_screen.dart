import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/device_group.dart';
import '../../domain/models/smart_device.dart';
import '../../domain/services/device_group_notifier.dart';
import '../../domain/services/device_manager.dart';

class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(deviceGroupProvider);
    final devicesAsync = ref.watch(deviceManagerProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        title: const Text('Groups', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF00E5FF),
        foregroundColor: Colors.black,
        onPressed: () => _showCreateGroupDialog(context, ref),
        child: const Icon(Icons.add),
      ),
      body: groupsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.red))),
        data: (groups) {
          if (groups.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.group_work_outlined, size: 64, color: Colors.white24),
                  SizedBox(height: 16),
                  Text('No groups yet', style: TextStyle(color: Colors.white54, fontSize: 16)),
                  SizedBox(height: 8),
                  Text('Tap + to create a room or zone',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            );
          }

          final devices = devicesAsync.valueOrNull ?? [];
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: groups.length,
            itemBuilder: (context, i) => _GroupCard(
              group: groups[i],
              devices: devices
                  .where((d) => groups[i].deviceIds.contains(d.uniqueDeviceId))
                  .toList(),
            ),
          );
        },
      ),
    );
  }

  void _showCreateGroupDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141929),
        title: const Text('New Group', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'e.g. Living Room',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF00E5FF))),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF00E5FF), width: 2)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                ref.read(deviceGroupProvider.notifier).createGroup(name);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Create', style: TextStyle(color: Color(0xFF00E5FF))),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends ConsumerWidget {
  final DeviceGroup group;
  final List<SmartDevice> devices;

  const _GroupCard({required this.group, required this.devices});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onlineCount = devices.where((d) => d.status == DeviceStatus.online).length;
    final notifier = ref.read(deviceGroupProvider.notifier);

    return Card(
      color: const Color(0xFF141929),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        iconColor: const Color(0xFF00E5FF),
        collapsedIconColor: Colors.white38,
        title: Text(group.name,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${devices.length} device${devices.length == 1 ? "" : "s"}'
          '${onlineCount > 0 ? "  •  $onlineCount online" : ""}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // All-off batch button
            IconButton(
              icon: const Icon(Icons.power_off, size: 20),
              color: Colors.white38,
              tooltip: 'Turn all off',
              onPressed: () => notifier.sendCommandToGroup(group.id, {'power': false}),
            ),
            // All-on batch button
            IconButton(
              icon: const Icon(Icons.power, size: 20),
              color: const Color(0xFF00E5FF),
              tooltip: 'Turn all on',
              onPressed: () => notifier.sendCommandToGroup(group.id, {'power': true}),
            ),
            // Delete group
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              color: Colors.red.shade300,
              tooltip: 'Delete group',
              onPressed: () => _confirmDelete(context, ref),
            ),
          ],
        ),
        children: [
          if (devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No devices in this group.',
                  style: TextStyle(color: Colors.white38, fontSize: 13)),
            )
          else
            ...devices.map((d) => ListTile(
                  dense: true,
                  leading: Icon(
                    d.status == DeviceStatus.online
                        ? Icons.circle
                        : Icons.circle_outlined,
                    size: 10,
                    color: d.status == DeviceStatus.online
                        ? Colors.greenAccent
                        : Colors.white24,
                  ),
                  title: Text(d.displayName,
                      style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        size: 18, color: Colors.white38),
                    tooltip: 'Remove from group',
                    onPressed: () =>
                        notifier.removeDevice(group.id, d.uniqueDeviceId),
                  ),
                )),
          // Add device row
          _AddDeviceRow(group: group),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141929),
        title: Text('Delete "${group.name}"?',
            style: const TextStyle(color: Colors.white)),
        content: const Text('This only removes the group — devices are unaffected.',
            style: TextStyle(color: Colors.white54)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              ref.read(deviceGroupProvider.notifier).deleteGroup(group.id);
              Navigator.pop(ctx);
            },
            child: Text('Delete', style: TextStyle(color: Colors.red.shade300)),
          ),
        ],
      ),
    );
  }
}

/// Row that lists devices not yet in this group and lets the user add one.
class _AddDeviceRow extends ConsumerWidget {
  final DeviceGroup group;

  const _AddDeviceRow({required this.group});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allDevices = ref.watch(deviceManagerProvider).valueOrNull ?? [];
    final available =
        allDevices.where((d) => !group.deviceIds.contains(d.uniqueDeviceId)).toList();

    if (available.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: PopupMenuButton<String>(
        color: const Color(0xFF1E2540),
        tooltip: 'Add device to group',
        itemBuilder: (_) => available
            .map((d) => PopupMenuItem<String>(
                  value: d.uniqueDeviceId,
                  child: Text(d.displayName,
                      style: const TextStyle(color: Colors.white70)),
                ))
            .toList(),
        onSelected: (deviceId) =>
            ref.read(deviceGroupProvider.notifier).addDevice(group.id, deviceId),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_circle_outline, size: 16, color: Color(0xFF00E5FF)),
            SizedBox(width: 6),
            Text('Add device',
                style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
