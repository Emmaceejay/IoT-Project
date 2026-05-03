import 'dart:convert';

enum DeviceStatus { online, offline, provisioning }

/// Represents a single Matter-compliant IoT Device in the ecosystem.
/// The [capabilities] list is the Schema-Driven UI contract — the app
/// reads this to decide which controls to render dynamically.
class MatterDevice {
  final String uniqueDeviceId; // e.g., MAC address or Matter Node ID
  final String deviceName;
  final DeviceStatus status;
  final List<String> capabilities; // e.g., ['relay', 'dimmer', 'temperature']
  final Map<String, dynamic> telemetry; // Latest known state payload

  const MatterDevice({
    required this.uniqueDeviceId,
    required this.deviceName,
    this.status = DeviceStatus.offline,
    this.capabilities = const [],
    this.telemetry = const {},
  });

  /// Parses a capability-discovery JSON payload from a connecting device.
  factory MatterDevice.fromJson(Map<String, dynamic> json) {
    return MatterDevice(
      uniqueDeviceId: json['device_id'] as String,
      deviceName: json['name'] as String,
      status: _parseStatus(json['status'] as String?),
      capabilities: List<String>.from(json['capabilities'] as List? ?? []),
      telemetry: json['telemetry'] as Map<String, dynamic>? ?? {},
    );
  }

  static DeviceStatus _parseStatus(String? raw) {
    switch (raw) {
      case 'online':
        return DeviceStatus.online;
      case 'provisioning':
        return DeviceStatus.provisioning;
      default:
        return DeviceStatus.offline;
    }
  }

  /// Produces a new instance with updated fields. Keeps data immutable.
  MatterDevice copyWith({
    String? deviceName,
    DeviceStatus? status,
    List<String>? capabilities,
    Map<String, dynamic>? telemetry,
  }) {
    return MatterDevice(
      uniqueDeviceId: uniqueDeviceId,
      deviceName: deviceName ?? this.deviceName,
      status: status ?? this.status,
      capabilities: capabilities ?? this.capabilities,
      telemetry: telemetry ?? this.telemetry,
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': uniqueDeviceId,
        'name': deviceName,
        'status': status.name,
        'capabilities': capabilities,
        'telemetry': telemetry,
      };

  @override
  String toString() => 'MatterDevice(id: $uniqueDeviceId, name: $deviceName, status: ${status.name})';
}
