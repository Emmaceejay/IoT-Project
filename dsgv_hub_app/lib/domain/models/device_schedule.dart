import 'dart:convert';
import 'dart:math';

class DeviceSchedule {
  final String id;
  final String deviceId;
  final String label;
  final int timeHour;
  final int timeMinute;

  /// 1=Mon … 7=Sun. Empty list means every day.
  final List<int> days;

  /// Raw MQTT payload passed to sendCommand, e.g. {'power': true}.
  final Map<String, dynamic> command;

  final bool enabled;
  final DateTime createdAt;

  const DeviceSchedule({
    required this.id,
    required this.deviceId,
    required this.label,
    required this.timeHour,
    required this.timeMinute,
    required this.days,
    required this.command,
    required this.enabled,
    required this.createdAt,
  });

  static String generateId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random();
    return List.generate(12, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  String get formattedTime {
    final h = timeHour.toString().padLeft(2, '0');
    final m = timeMinute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String get formattedDays {
    if (days.isEmpty) return 'Every day';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days.map((d) => names[d - 1]).join(', ');
  }

  DeviceSchedule copyWith({
    String? id,
    String? deviceId,
    String? label,
    int? timeHour,
    int? timeMinute,
    List<int>? days,
    Map<String, dynamic>? command,
    bool? enabled,
    DateTime? createdAt,
  }) {
    return DeviceSchedule(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      label: label ?? this.label,
      timeHour: timeHour ?? this.timeHour,
      timeMinute: timeMinute ?? this.timeMinute,
      days: days ?? this.days,
      command: command ?? this.command,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'label': label,
        'timeHour': timeHour,
        'timeMinute': timeMinute,
        'days': days,
        'command': command,
        'enabled': enabled,
        'createdAt': createdAt.toIso8601String(),
      };

  factory DeviceSchedule.fromJson(Map<String, dynamic> json) {
    return DeviceSchedule(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      label: json['label'] as String,
      timeHour: json['timeHour'] as int,
      timeMinute: json['timeMinute'] as int,
      days: (json['days'] as List<dynamic>).map((e) => e as int).toList(),
      command: Map<String, dynamic>.from(
          jsonDecode(jsonEncode(json['command'])) as Map),
      enabled: json['enabled'] as bool,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceSchedule &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
