import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/smart_device.dart';
import '../../domain/models/room.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/room_service.dart';
import '../widgets/device_card.dart';
import 'device_pairing_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String? _selectedRoomId; // null = All
  String _categoryFilter = 'all'; // 'all' | 'switches' | 'lights' | 'sensors'

  // ── Filtering ──────────────────────────────────────────────────────────────

  List<SmartDevice> _filterDevices(
      List<SmartDevice> devices, RoomState roomState) {
    var result = devices;

    if (_selectedRoomId != null) {
      result = result
          .where((d) =>
              roomState.roomIdForDevice(d.uniqueDeviceId) == _selectedRoomId)
          .toList();
    }

    switch (_categoryFilter) {
      case 'switches':
        result = result
            .where((d) => d.capabilities
                .any((c) => c == 'relay' || c.startsWith('relay_')))
            .toList();
      case 'lights':
        result = result
            .where((d) => d.capabilities.any(
                (c) => ['brightness', 'color_temp', 'rgb'].contains(c)))
            .toList();
      case 'sensors':
        result = result
            .where((d) => d.capabilities.any((c) =>
                ['temperature', 'humidity', 'motion', 'contact'].contains(c)))
            .toList();
    }

    return result;
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _showAddSheet(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: const Color(0xFF121826),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Add Device',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18),
              ),
              const SizedBox(height: 16),
              _AddOptionTile(
                icon: Icons.qr_code_scanner,
                title: 'Scan QR code',
                subtitle: 'Use your camera to scan the QR label on the device',
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.of(ctx).push(MaterialPageRoute(
                    builder: (_) =>
                        const DevicePairingScreen(openScanner: true),
                  ));
                },
              ),
              const Divider(color: Colors.white12, height: 8),
              _AddOptionTile(
                icon: Icons.keyboard,
                title: 'Enter pair code',
                subtitle: 'Type the 6-char code printed on the device label',
                iconColor: Colors.white54,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.of(ctx).push(MaterialPageRoute(
                    builder: (_) =>
                        const DevicePairingScreen(openScanner: false),
                  ));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAddRoomDialog(BuildContext ctx) async {
    final room = await showDialog<Room>(
      context: ctx,
      builder: (_) => const _AddRoomDialog(),
    );
    if (room != null && mounted) {
      await ref.read(roomServiceProvider.notifier).addRoom(room);
    }
  }

  Future<void> _confirmDeleteRoom(BuildContext ctx, Room room) async {
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF121826),
        title: const Text('Delete Room?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Delete "${room.name}"? Devices assigned to it will become unassigned.',
          style: const TextStyle(
              color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(roomServiceProvider.notifier).removeRoom(room.id);
      if (_selectedRoomId == room.id) {
        setState(() => _selectedRoomId = null);
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final deviceState = ref.watch(deviceManagerProvider);
    final roomAsync = ref.watch(roomServiceProvider);
    final roomState = roomAsync.valueOrNull ?? const RoomState();

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
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white54),
            tooltip: 'Refresh',
            onPressed: () =>
                ref.read(deviceManagerProvider.notifier).refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.add, color: Color(0xFF00E5FF)),
            tooltip: 'Add Device',
            onPressed: () => _showAddSheet(context),
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
        data: (devices) => _buildContent(context, devices, roomState),
      ),
    );
  }

  Widget _buildContent(
      BuildContext ctx, List<SmartDevice> devices, RoomState roomState) {
    final filtered = _filterDevices(devices, roomState);
    final online =
        filtered.where((d) => d.status == DeviceStatus.online).toList();
    final offline =
        filtered.where((d) => d.status != DeviceStatus.online).toList();

    return RefreshIndicator(
      color: const Color(0xFF00E5FF),
      onRefresh: () => ref.read(deviceManagerProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          // ── Summary stats (always global counts) ───────────────────────
          _SummaryRow(
            total: devices.length,
            online: devices.where((d) => d.status == DeviceStatus.online).length,
          ),
          const SizedBox(height: 16),

          // ── Room filter chips ──────────────────────────────────────────
          _RoomChipsBar(
            rooms: roomState.rooms,
            selectedId: _selectedRoomId,
            onSelect: (id) => setState(() => _selectedRoomId = id),
            onLongPress: (room) => _confirmDeleteRoom(ctx, room),
            onAddRoom: () => _showAddRoomDialog(ctx),
          ),
          const SizedBox(height: 8),

          // ── Category filter ────────────────────────────────────────────
          _CategoryFilterBar(
            selected: _categoryFilter,
            onSelect: (c) => setState(() => _categoryFilter = c),
          ),
          const SizedBox(height: 16),

          // ── Empty state ────────────────────────────────────────────────
          if (devices.isEmpty)
            _buildEmptyState(
                icon: Icons.devices_other,
                message:
                    'No devices yet.\nTap the + button to pair your first device.')
          else if (filtered.isEmpty)
            _buildEmptyState(
              icon: Icons.search_off,
              message: _selectedRoomId != null
                  ? 'No devices in this room.\nOpen Device Settings to assign devices.'
                  : 'No ${_categoryFilter == "all" ? "devices" : _categoryFilter} found.',
            )
          else ...[
            // ── Online ─────────────────────────────────────────────────
            if (online.isNotEmpty) ...[
              _SectionHeader(
                  label: 'Online',
                  count: online.length,
                  color: const Color(0xFF00E5FF)),
              ...online.map((d) => _dismissibleCard(ctx, d)),
              const SizedBox(height: 16),
            ],

            // ── Offline ────────────────────────────────────────────────
            if (offline.isNotEmpty) ...[
              _SectionHeader(
                  label: 'Offline', count: offline.length, color: Colors.grey),
              ...offline.map((d) => _dismissibleCard(ctx, d)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState({required IconData icon, required String message}) {
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          Icon(icon, size: 48, color: Colors.white12),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _dismissibleCard(BuildContext ctx, SmartDevice d) {
    return Dismissible(
      key: Key(d.uniqueDeviceId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: Colors.redAccent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, color: Colors.white, size: 22),
            SizedBox(height: 2),
            Text('Remove',
                style: TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(ctx, d.displayName),
      onDismissed: (_) => ref
          .read(deviceManagerProvider.notifier)
          .removeDevice(d.uniqueDeviceId),
      child: DeviceCard(device: d),
    );
  }

  Future<bool?> _confirmDelete(BuildContext ctx, String deviceName) {
    return showDialog<bool>(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF121826),
        title: const Text('Remove Device?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Remove "$deviceName"? It can be re-added by re-pairing.',
          style: const TextStyle(
              color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

// ── Room chips bar ────────────────────────────────────────────────────────────

class _RoomChipsBar extends StatelessWidget {
  final List<Room> rooms;
  final String? selectedId;
  final ValueChanged<String?> onSelect;
  final ValueChanged<Room> onLongPress;
  final VoidCallback onAddRoom;

  const _RoomChipsBar({
    required this.rooms,
    required this.selectedId,
    required this.onSelect,
    required this.onLongPress,
    required this.onAddRoom,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _RoomChip(
            label: 'All',
            selected: selectedId == null,
            onTap: () => onSelect(null),
          ),
          ...rooms.map((room) => Padding(
                padding: const EdgeInsets.only(left: 8),
                child: _RoomChip(
                  label: room.name,
                  color: room.color,
                  icon: room.icon,
                  selected: selectedId == room.id,
                  onTap: () => onSelect(room.id),
                  onLongPress: () => onLongPress(room),
                ),
              )),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: GestureDetector(
              onTap: onAddRoom,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white12),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14, color: Colors.white38),
                    SizedBox(width: 4),
                    Text('Add room',
                        style:
                            TextStyle(color: Colors.white38, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final IconData? icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _RoomChip({
    required this.label,
    required this.selected,
    this.color,
    this.icon,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final chipColor = color ?? const Color(0xFF00E5FF);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? chipColor.withValues(alpha: 0.15)
              : const Color(0xFF121826),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? chipColor : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14,
                  color: selected ? chipColor : Colors.white38),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? chipColor : Colors.white54,
                fontSize: 13,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Category filter bar ────────────────────────────────────────────────────────

class _CategoryFilterBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;

  const _CategoryFilterBar({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _CategoryChip(label: 'All',      value: 'all',      selected: selected == 'all',      onTap: () => onSelect('all')),
          const SizedBox(width: 8),
          _CategoryChip(label: 'Switches', value: 'switches', selected: selected == 'switches', onTap: () => onSelect('switches')),
          const SizedBox(width: 8),
          _CategoryChip(label: 'Lights',   value: 'lights',   selected: selected == 'lights',   onTap: () => onSelect('lights')),
          const SizedBox(width: 8),
          _CategoryChip(label: 'Sensors',  value: 'sensors',  selected: selected == 'sensors',  onTap: () => onSelect('sensors')),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF00E5FF).withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? const Color(0xFF00E5FF) : Colors.white12,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF00E5FF) : Colors.white38,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── Add Device sheet option tile ───────────────────────────────────────────────

class _AddOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color iconColor;
  final VoidCallback onTap;

  const _AddOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.iconColor = const Color(0xFF00E5FF),
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Colors.white38, fontSize: 12)),
      trailing:
          const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
      onTap: onTap,
    );
  }
}

// ── Add Room dialog ────────────────────────────────────────────────────────────

class _AddRoomDialog extends StatefulWidget {
  const _AddRoomDialog();

  @override
  State<_AddRoomDialog> createState() => _AddRoomDialogState();
}

class _AddRoomDialogState extends State<_AddRoomDialog> {
  final _nameCtrl = TextEditingController();
  Color _selectedColor = Room.colorOptions.first;
  String _selectedIconKey = 'home';

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF121826),
      title: const Text('New Room',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'e.g. Living Room',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF0A0E1A),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF00E5FF))),
              ),
            ),
            const SizedBox(height: 20),

            // Color picker
            const Text('Colour',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: Room.colorOptions.map((c) {
                final isSelected = _selectedColor.toARGB32() == c.toARGB32();
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = c),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? Colors.white : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white, size: 16)
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // Icon picker
            const Text('Icon',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: Room.iconOptions.entries.map((e) {
                final isSelected = _selectedIconKey == e.key;
                return GestureDetector(
                  onTap: () => setState(() => _selectedIconKey = e.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? _selectedColor.withValues(alpha: 0.18)
                          : const Color(0xFF0A0E1A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected ? _selectedColor : Colors.white12,
                      ),
                    ),
                    child: Icon(e.value,
                        size: 20,
                        color: isSelected ? _selectedColor : Colors.white38),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel',
              style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00E5FF),
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _nameCtrl.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    Room(
                      id: Room.generateId(),
                      name: _nameCtrl.text.trim(),
                      color: _selectedColor,
                      iconKey: _selectedIconKey,
                    ),
                  ),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

// ── Summary row ────────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final int total;
  final int online;

  const _SummaryRow({required this.total, required this.online});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StatCard(label: 'Total', value: total.toString()),
        const SizedBox(width: 12),
        _StatCard(
            label: 'Online',
            value: online.toString(),
            color: const Color(0xFF00E5FF)),
        const SizedBox(width: 12),
        _StatCard(
            label: 'Offline',
            value: (total - online).toString(),
            color: Colors.grey),
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
                    color: color,
                    fontSize: 24,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

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
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 14),
          ),
        ],
      ),
    );
  }
}
