import 'package:flutter/material.dart';

/// A named group of devices (e.g. "Living Room", "Bedroom").
/// Rooms are persisted to a JSON file via [RoomNotifier] — no ObjectBox
/// entity needed since there are typically only 5–15 rooms.
class Room {
  final String id;
  final String name;
  final Color color;

  /// Key into [iconOptions] — stored as a string so no codePoint maths needed.
  final String iconKey;

  const Room({
    required this.id,
    required this.name,
    this.color = const Color(0xFF00E5FF),
    this.iconKey = 'home',
  });

  IconData get icon => iconOptions[iconKey] ?? Icons.home_outlined;

  Room copyWith({String? name, Color? color, String? iconKey}) => Room(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        iconKey: iconKey ?? this.iconKey,
      );

  factory Room.fromJson(Map<String, dynamic> j) => Room(
        id: j['id'] as String,
        name: j['name'] as String,
        color: Color(j['color'] as int? ?? 0xFF00E5FF),
        iconKey: j['iconKey'] as String? ?? 'home',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color.toARGB32(),
        'iconKey': iconKey,
      };

  static String generateId() =>
      '${DateTime.now().millisecondsSinceEpoch}${DateTime.now().microsecond}';

  // ── Predefined options shown in the "create room" dialog ─────────────────

  static const Map<String, IconData> iconOptions = {
    'home': Icons.home_outlined,
    'sofa': Icons.weekend_outlined,
    'bed': Icons.bed_outlined,
    'kitchen': Icons.kitchen_outlined,
    'bath': Icons.bathroom_outlined,
    'work': Icons.work_outline,
    'garage': Icons.garage_outlined,
    'yard': Icons.yard_outlined,
    'dining': Icons.restaurant_outlined,
    'door': Icons.meeting_room_outlined,
    'game': Icons.sports_esports_outlined,
    'gym': Icons.fitness_center_outlined,
  };

  static const List<Color> colorOptions = [
    Color(0xFF00E5FF),
    Color(0xFF4CAF50),
    Color(0xFFFF9800),
    Color(0xFFE91E63),
    Color(0xFF9C27B0),
    Color(0xFF2196F3),
    Color(0xFFFF5722),
    Color(0xFF009688),
  ];
}
