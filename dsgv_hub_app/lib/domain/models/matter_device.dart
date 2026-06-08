enum DeviceStatus { online, offline, provisioning }

/// What the device's relay(s) should do when power is restored after an outage.
enum PowerRestoreMode {
  /// Relay(s) stay OFF — safest default; user must switch on manually.
  off,

  /// Relay(s) return to whatever state they were in before the power loss.
  restore,

  /// Relay(s) always turn ON after power is restored.
  on,
}

/// Represents a single Matter-compliant IoT Device in the ecosystem.
/// The [capabilities] list is the Schema-Driven UI contract — the app
/// reads this to decide which controls to render dynamically.
class MatterDevice {
  final String uniqueDeviceId; // e.g., MAC address or Matter Node ID
  final String deviceName;
  final DeviceStatus status;
  final List<String> capabilities; // e.g., ['relay', 'dimmer', 'temperature']
  final Map<String, dynamic> telemetry; // Latest known state payload
  final String? localIp; // Direct HTTP transport (Tasmota-style, same LAN)

  // 32-char hex token exchanged over BLE at first provisioning.
  // Never transmitted over MQTT. Used to authenticate broker-change commands.
  final String? authToken;

  // User-set label. Null = use auto-generated deviceName.
  final String? customName;

  /// Power restore preference for relay devices. Synced to/from firmware via MQTT.
  final PowerRestoreMode powerRestoreMode;

  /// Model identifier matching the firmware manifest key, e.g. "1gang_switch".
  /// Populated from the "device_type" field in the MQTT announce message.
  /// Empty string means the device is running firmware older than the manifest feature.
  final String deviceType;

  /// Firmware version string reported by the device, e.g. "1.0.0".
  /// Populated from the "firmware" field in the MQTT announce message.
  final String firmwareVersion;

  /// What to show in the UI — user's custom label if set, firmware name otherwise.
  String get displayName =>
      (customName != null && customName!.isNotEmpty) ? customName! : deviceName;

  const MatterDevice({
    required this.uniqueDeviceId,
    required this.deviceName,
    this.status = DeviceStatus.offline,
    this.capabilities = const [],
    this.telemetry = const {},
    this.localIp,
    this.authToken,
    this.customName,
    this.powerRestoreMode = PowerRestoreMode.off,
    this.deviceType = '',
    this.firmwareVersion = '',
  });

  /// Parses a capability-discovery JSON payload from a connecting device.
  factory MatterDevice.fromJson(Map<String, dynamic> json) {
    return MatterDevice(
      uniqueDeviceId: json['device_id'] as String,
      deviceName: json['name'] as String,
      status: _parseStatus(json['status'] as String?),
      capabilities: List<String>.from(json['capabilities'] as List? ?? []),
      telemetry: json['telemetry'] as Map<String, dynamic>? ?? {},
      localIp: json['local_ip'] as String?,
      powerRestoreMode: _parseRestoreMode(json['power_restore'] as String?),
      deviceType: json['device_type'] as String? ?? '',
      firmwareVersion: json['firmware'] as String? ?? '',
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
    String? localIp,
    String? authToken,
    Object? customName = _sentinel,
    PowerRestoreMode? powerRestoreMode,
    String? deviceType,
    String? firmwareVersion,
  }) {
    return MatterDevice(
      uniqueDeviceId: uniqueDeviceId,
      deviceName: deviceName ?? this.deviceName,
      status: status ?? this.status,
      capabilities: capabilities ?? this.capabilities,
      telemetry: telemetry ?? this.telemetry,
      localIp: localIp ?? this.localIp,
      authToken: authToken ?? this.authToken,
      customName: customName == _sentinel ? this.customName : customName as String?,
      powerRestoreMode: powerRestoreMode ?? this.powerRestoreMode,
      deviceType: deviceType ?? this.deviceType,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
    );
  }

  // Sentinel allows passing null explicitly to clear the custom name.
  static const Object _sentinel = Object();

  Map<String, dynamic> toJson() => {
        'device_id': uniqueDeviceId,
        'name': deviceName,
        'status': status.name,
        'capabilities': capabilities,
        'telemetry': telemetry,
        'power_restore': powerRestoreMode.name,
        if (localIp != null) 'local_ip': localIp,
      };

  static PowerRestoreMode _parseRestoreMode(String? raw) {
    switch (raw) {
      case 'restore': return PowerRestoreMode.restore;
      case 'on':      return PowerRestoreMode.on;
      default:        return PowerRestoreMode.off;
    }
  }

  @override
  String toString() => 'MatterDevice(id: $uniqueDeviceId, name: $deviceName, status: ${status.name})';
}
