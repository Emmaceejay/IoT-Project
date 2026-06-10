import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/smart_device.dart';
import '../../domain/models/room.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/room_service.dart';
import '../widgets/device_card.dart';
import 'device_pairing_screen.dart';
import 'ap_provisioning_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String? _selectedRoomId; // null = All
  String _categoryFilter = 'all'; // 'all' | 'switches' | 'lights' | 'sensors'
  bool _filtersExpanded = false;

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

  // ── Filter summary ─────────────────────────────────────────────────────────

  String _filterSummary(RoomState roomState) {
    final roomLabel = _selectedRoomId != null
        ? roomState.rooms
            .firstWhere(
              (r) => r.id == _selectedRoomId,
              orElse: () => const Room(
                  id: '', name: 'Room', color: Colors.white, iconKey: 'home'),
            )
            .name
        : 'All Rooms';
    final catLabel = switch (_categoryFilter) {
      'switches' => 'Switches',
      'lights' => 'Lights',
      'sensors' => 'Sensors',
      _ => 'All Devices',
    };
    return '$roomLabel  ·  $catLabel';
  }

  bool get _hasActiveFilter =>
      _selectedRoomId != null || _categoryFilter != 'all';

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
                    builder: (_) => const DevicePairingScreen(openScanner: true),
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
                    builder: (_) => const DevicePairingScreen(openScanner: false),
                  ));
                },
              ),
              const Divider(color: Colors.white12, height: 8),
              _AddOptionTile(
                icon: Icons.bluetooth_searching,
                title: 'Scan for nearby devices',
                subtitle: 'Auto-discover DSGV devices broadcasting via Bluetooth',
                iconColor: const Color(0xFF00E5FF),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.of(ctx).push(MaterialPageRoute(
                    builder: (_) => const DevicePairingScreen(bleScanMode: true),
                  ));
                },
              ),
              const Divider(color: Colors.white12, height: 8),
              _AddOptionTile(
                icon: Icons.wifi_tethering,
                title: 'Join via device Wi-Fi',
                subtitle: 'Connect directly to the device\'s setup hotspot',
                iconColor: Colors.tealAccent,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.of(ctx).push(MaterialPageRoute(
                    builder: (_) => const ApProvisioningScreen(),
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
              style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 0.3),
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
        children: [
          // ── Collapsible filter panel ───────────────────────────────────
          _CollapsibleFilterPanel(
            expanded: _filtersExpanded,
            summary: _filterSummary(roomState),
            hasActiveFilter: _hasActiveFilter,
            onToggle: () =>
                setState(() => _filtersExpanded = !_filtersExpanded),
            rooms: roomState.rooms,
            selectedRoomId: _selectedRoomId,
            onRoomSelect: (id) => setState(() => _selectedRoomId = id),
            onRoomLongPress: (room) => _confirmDeleteRoom(ctx, room),
            onAddRoom: () => _showAddRoomDialog(ctx),
            categoryFilter: _categoryFilter,
            onCategorySelect: (c) =>
                setState(() => _categoryFilter = c),
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
      height: 36,
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
            width: selected ? 1.5 : 1.0,
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

// ── Collapsible filter panel ──────────────────────────────────────────────────

class _CollapsibleFilterPanel extends StatelessWidget {
  final bool expanded;
  final String summary;
  final bool hasActiveFilter;
  final VoidCallback onToggle;
  final List<Room> rooms;
  final String? selectedRoomId;
  final ValueChanged<String?> onRoomSelect;
  final ValueChanged<Room> onRoomLongPress;
  final VoidCallback onAddRoom;
  final String categoryFilter;
  final ValueChanged<String> onCategorySelect;

  const _CollapsibleFilterPanel({
    required this.expanded,
    required this.summary,
    required this.hasActiveFilter,
    required this.onToggle,
    required this.rooms,
    required this.selectedRoomId,
    required this.onRoomSelect,
    required this.onRoomLongPress,
    required this.onAddRoom,
    required this.categoryFilter,
    required this.onCategorySelect,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5FF);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Collapsed summary pill ─────────────────────────────────────
        GestureDetector(
          onTap: onToggle,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF121826),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hasActiveFilter
                    ? accent.withValues(alpha: 0.35)
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: hasActiveFilter ? accent : Colors.white38,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    summary,
                    style: TextStyle(
                      color: hasActiveFilter
                          ? accent.withValues(alpha: 0.85)
                          : Colors.white38,
                      fontSize: 13,
                      fontWeight: hasActiveFilter
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasActiveFilter)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent,
                    ),
                  ),
              ],
            ),
          ),
        ),

        // ── Expanded panel ─────────────────────────────────────────────
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _RoomChipsBar(
                        rooms: rooms,
                        selectedId: selectedRoomId,
                        onSelect: onRoomSelect,
                        onLongPress: onRoomLongPress,
                        onAddRoom: onAddRoom,
                      ),
                      const SizedBox(height: 10),
                      _CategoryTabBar(
                        selected: categoryFilter,
                        onSelect: onCategorySelect,
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

// ── Category tab bar ──────────────────────────────────────────────────────────

class _CategoryTabBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;

  const _CategoryTabBar({required this.selected, required this.onSelect});

  static const _tabs = [
    ('all', 'All', Icons.apps_rounded),
    ('switches', 'Switches', Icons.toggle_on_outlined),
    ('lights', 'Lights', Icons.lightbulb_outline),
    ('sensors', 'Sensors', Icons.sensors_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Divider(
          color: Colors.white.withValues(alpha: 0.06),
          height: 1,
          thickness: 1,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: _tabs
              .map((t) => _CategoryTab(
                    value: t.$1,
                    label: t.$2,
                    icon: t.$3,
                    selected: selected == t.$1,
                    onTap: () => onSelect(t.$1),
                  ))
              .toList(),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _CategoryTab extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryTab({
    required this.value,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5FF);
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? accent : Colors.white38,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? accent : Colors.white38,
                fontSize: 11,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: selected ? 1.0 : 0.0,
              child: Container(
                height: 2,
                width: 20,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ],
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

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _SectionHeader(
      {required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: color.withValues(alpha: 0.7),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: color.withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(
              color: color.withValues(alpha: 0.5),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
