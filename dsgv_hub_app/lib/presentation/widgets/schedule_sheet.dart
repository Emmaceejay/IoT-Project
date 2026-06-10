import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/device_schedule.dart';
import '../../domain/models/smart_device.dart';
import '../../domain/services/schedule_service.dart';

/// Bottom sheet for adding or editing a device schedule.
/// Pass [existing] to open in edit mode; leave null for a new schedule.
class ScheduleSheet extends ConsumerStatefulWidget {
  final SmartDevice device;
  final DeviceSchedule? existing;

  const ScheduleSheet({super.key, required this.device, this.existing});

  @override
  ConsumerState<ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<ScheduleSheet> {
  static const _dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _dayNames = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
  ];

  late TimeOfDay _time;
  late List<int> _selectedDays;
  late Map<String, dynamic> _command;
  late TextEditingController _labelCtrl;

  // Controllable capabilities and their initial command values
  static const _readOnly = {
    'temperature', 'humidity', 'motion', 'contact'
  };

  List<String> get _controllable => widget.device.capabilities
      .where((c) => !_readOnly.contains(c))
      .toList();

  bool get _hasControllable => _controllable.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _time = e != null
        ? TimeOfDay(hour: e.timeHour, minute: e.timeMinute)
        : TimeOfDay.now();
    _selectedDays = e != null ? List<int>.from(e.days) : [];
    _command = e != null ? Map<String, dynamic>.from(e.command) : {};
    _labelCtrl = TextEditingController(text: e?.label ?? '');

    if (e == null && _controllable.isNotEmpty) {
      _initDefaultCommand();
    }
  }

  void _initDefaultCommand() {
    final cap = _controllable.first;
    if (cap.startsWith('relay')) {
      final key = _relayKey(cap);
      _command[key] = true;
    } else if (cap == 'brightness') {
      _command['brightness'] = 75;
    } else if (cap == 'color_temp') {
      _command['color_temp'] = 4000;
    }
  }

  String _relayKey(String cap) => switch (cap) {
        'relay' => 'power',
        'relay_2' => 'power_2',
        'relay_3' => 'power_3',
        _ => 'power_4',
      };

  String _autoLabel() {
    final h = _time.hour.toString().padLeft(2, '0');
    final m = _time.minute.toString().padLeft(2, '0');
    if (_command.isEmpty) return '$h:$m';
    final firstVal = _command.values.first;
    final suffix = firstVal == true
        ? 'ON'
        : firstVal == false
            ? 'OFF'
            : '$firstVal';
    return '$h:$m $suffix';
  }

  bool get _canSave =>
      _hasControllable && _command.isNotEmpty;

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF00E5FF),
            onPrimary: Colors.black,
            surface: Color(0xFF121826),
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _time = picked;
        if (_labelCtrl.text.isEmpty) {
          _labelCtrl.text = _autoLabel();
        }
      });
    }
  }

  void _toggleDay(int day) {
    setState(() {
      if (_selectedDays.contains(day)) {
        _selectedDays.remove(day);
      } else {
        _selectedDays.add(day);
        _selectedDays.sort();
      }
    });
  }

  Future<void> _save() async {
    final label =
        _labelCtrl.text.trim().isEmpty ? _autoLabel() : _labelCtrl.text.trim();
    final notifier = ref.read(scheduleServiceProvider.notifier);

    if (widget.existing != null) {
      await notifier.updateSchedule(widget.existing!.copyWith(
        label: label,
        timeHour: _time.hour,
        timeMinute: _time.minute,
        days: _selectedDays,
        command: _command,
      ));
    } else {
      await notifier.addSchedule(DeviceSchedule(
        id: DeviceSchedule.generateId(),
        deviceId: widget.device.uniqueDeviceId,
        label: label,
        timeHour: _time.hour,
        timeMinute: _time.minute,
        days: _selectedDays,
        command: _command,
        enabled: true,
        createdAt: DateTime.now(),
      ));
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF121826),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 8, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
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

            Text(
              widget.existing != null ? 'Edit Schedule' : 'New Schedule',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),

            // ── Label ────────────────────────────────────────────────
            const _Label('Label'),
            const SizedBox(height: 6),
            TextField(
              controller: _labelCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'e.g. Morning ON',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF0A0E1A),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide:
                        const BorderSide(color: Color(0xFF00E5FF))),
              ),
            ),
            const SizedBox(height: 16),

            // ── Time ─────────────────────────────────────────────────
            const _Label('Time'),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: _pickTime,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0E1A),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.access_time,
                        color: Color(0xFF00E5FF), size: 18),
                    const SizedBox(width: 10),
                    Text(
                      _time.format(context),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    const Icon(Icons.chevron_right,
                        color: Colors.white24, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Days ─────────────────────────────────────────────────
            const _Label('Repeat'),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(7, (i) {
                final day = i + 1;
                final isSelected = _selectedDays.contains(day);
                return GestureDetector(
                  onTap: () => _toggleDay(day),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF00E5FF).withValues(alpha: 0.15)
                          : const Color(0xFF0A0E1A),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF00E5FF)
                            : Colors.white12,
                        width: isSelected ? 1.5 : 1.0,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        _dayLabels[i],
                        style: TextStyle(
                          color: isSelected
                              ? const Color(0xFF00E5FF)
                              : Colors.white38,
                          fontSize: 11,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            if (_selectedDays.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Every day',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 11),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _selectedDays.map((d) => _dayNames[d - 1]).join(', '),
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 11),
                ),
              ),
            const SizedBox(height: 16),

            // ── Action ───────────────────────────────────────────────
            const _Label('Action'),
            const SizedBox(height: 8),
            if (!_hasControllable)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: const Text(
                  'This device has no controllable capabilities.',
                  style:
                      TextStyle(color: Colors.white38, fontSize: 13),
                ),
              )
            else
              _buildCommandControls(),
            const SizedBox(height: 24),

            // ── Buttons ──────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white54,
                      side: const BorderSide(color: Colors.white12),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _canSave
                          ? const Color(0xFF00E5FF)
                          : const Color(0xFF1E2A3A),
                      foregroundColor:
                          _canSave ? Colors.black : Colors.white38,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _canSave ? _save : null,
                    child: const Text('Save',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandControls() {
    return Column(
      children: _controllable.map((cap) {
        if (cap.startsWith('relay')) {
          final key = _relayKey(cap);
          final isOn = _command[key] as bool? ?? true;
          final gangLabel = switch (cap) {
            'relay_2' => ' (Gang 2)',
            'relay_3' => ' (Gang 3)',
            'relay_4' => ' (Gang 4)',
            _ => '',
          };
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E1A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Row(
                children: [
                  Text(
                    'Switch$gangLabel',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 14),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () =>
                        setState(() => _command[key] = !isOn),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: isOn
                            ? const Color(0xFF00E5FF)
                                .withValues(alpha: 0.15)
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isOn
                              ? const Color(0xFF00E5FF)
                              : Colors.white24,
                          width: 1.0,
                        ),
                      ),
                      child: Text(
                        isOn ? 'Turn ON' : 'Turn OFF',
                        style: TextStyle(
                          color: isOn
                              ? const Color(0xFF00E5FF)
                              : Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        if (cap == 'brightness') {
          final val = (_command['brightness'] as num? ?? 75).toDouble();
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E1A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Brightness',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 14)),
                      Text('${val.round()}%',
                          style: const TextStyle(
                              color: Color(0xFF00E5FF),
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Slider(
                    value: val,
                    min: 0,
                    max: 100,
                    divisions: 20,
                    activeColor: const Color(0xFF00E5FF),
                    inactiveColor:
                        const Color(0xFF00E5FF).withValues(alpha: 0.2),
                    onChanged: (v) =>
                        setState(() => _command['brightness'] = v.round()),
                  ),
                ],
              ),
            ),
          );
        }

        if (cap == 'color_temp') {
          final val =
              (_command['color_temp'] as num? ?? 4000).toDouble();
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E1A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Colour Temp',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 14)),
                      Text('${val.round()}K',
                          style: const TextStyle(
                              color: Color(0xFF00E5FF),
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Slider(
                    value: val,
                    min: 2700,
                    max: 6500,
                    divisions: 38,
                    activeColor: const Color(0xFF00E5FF),
                    inactiveColor:
                        const Color(0xFF00E5FF).withValues(alpha: 0.2),
                    onChanged: (v) => setState(
                        () => _command['color_temp'] = v.round()),
                  ),
                ],
              ),
            ),
          );
        }

        return const SizedBox.shrink();
      }).toList(),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
          color: Colors.white54,
          fontSize: 12,
          fontWeight: FontWeight.w500),
    );
  }
}
