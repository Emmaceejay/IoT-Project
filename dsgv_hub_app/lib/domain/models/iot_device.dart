/// Represents a single IoT device managed by the DSGV Hub.
///
/// This is the central domain model. Every layer of the app — the local
/// ObjectBox cache, MQTT message parsing, the UI, and the mDNS discovery
/// service — works with [IoTDevice] instances.
///
/// Design notes:
///   - The class is **immutable**. State changes always produce a new instance
///     via [copyWith]. This makes Riverpod state diffing reliable and cheap.
///   - [capabilities] is the schema-driven UI contract. The app renders
///     controls dynamically based on this list — adding a new device type
///     never requires a new screen, just a new capability string.
///   - [localIp] is populated by mDNS discovery or the MQTT announce message.
///     When present, direct HTTP commands bypass the broker entirely.
enum DeviceStatus { online, offline, provisioning }

class IoTDevice {
  /// Unique identifier — the device's WiFi MAC address in uppercase hex
  /// with no separators, e.g. "A1B2C3D4E5F6".
  /// This matches the MQTT topic prefix "devices/<uniqueDeviceId>/…".
  final String uniqueDeviceId;

  /// Human-readable label assigned by the user during provisioning,
  /// e.g. "Kitchen Switch" or "Bedroom Dimmer".
  final String deviceName;

  /// Current connectivity state of the device.
  final DeviceStatus status;

  /// List of capability strings that define what this device can do.
  /// Examples: ['relay'], ['relay', 'brightness'], ['temperature', 'humidity']
  ///
  /// The [SchemaDriverUiBuilder] reads this list to render the correct
  /// controls — power toggle, brightness slider, colour picker, etc.
  /// It also drives the C2C voice trait mapping in the cloud bridge.
  final List<String> capabilities;

  /// The latest known state of the device, e.g.:
  ///   { "power": true, "brightness": 75, "color_temp": 4000 }
  /// Updated every time a telemetry message arrives over MQTT.
  final Map<String, dynamic> telemetry;

  /// LAN IP address of the device (e.g. "192.168.1.42").
  /// Populated by:
  ///   a. The MQTT announce message (device publishes its own IP), or
  ///   b. mDNS discovery (app queries _dsgv._tcp.local on the LAN).
  /// When non-null, commands are sent directly via HTTP for <10 ms latency
  /// instead of going through the MQTT broker.
  final String? localIp;

  /// 32-character hex authentication token generated on the device using
  /// hardware entropy (esp_random). Exchanged only over BLE during first
  /// provisioning — never transmitted over MQTT.
  /// Used to authenticate broker-configuration change commands from the app.
  final String? authToken;

  const IoTDevice({
    required this.uniqueDeviceId,
    required this.deviceName,
    this.status = DeviceStatus.offline,
    this.capabilities = const [],
    this.telemetry = const {},
    this.localIp,
    this.authToken,
  });

  /// Parses the JSON payload from a device MQTT announce message or an mDNS
  /// TXT record set. Both sources use the same key names.
  ///
  /// Expected keys:
  ///   device_id    — String, the MAC-based unique ID
  ///   name         — String, device label
  ///   status       — String?, "online" | "offline" | "provisioning"
  ///   capabilities — List<String>?, e.g. ["relay", "brightness"]
  ///   telemetry    — Map<String, dynamic>?, latest known state
  ///   local_ip     — String?, LAN IP address
  factory IoTDevice.fromJson(Map<String, dynamic> json) {
    return IoTDevice(
      uniqueDeviceId: json['device_id'] as String,
      deviceName:     json['name']      as String,
      status:         _parseStatus(json['status'] as String?),
      capabilities:   List<String>.from(json['capabilities'] as List? ?? []),
      telemetry:      json['telemetry'] as Map<String, dynamic>? ?? {},
      localIp:        json['local_ip']  as String?,
    );
  }

  /// Converts the device back to a JSON map for storage or debug logging.
  Map<String, dynamic> toJson() => {
        'device_id':    uniqueDeviceId,
        'name':         deviceName,
        'status':       status.name,
        'capabilities': capabilities,
        'telemetry':    telemetry,
        if (localIp != null) 'local_ip': localIp,
      };

  /// Returns a new [IoTDevice] with the specified fields replaced.
  /// All other fields are copied from this instance.
  /// Use this whenever device state changes — never mutate in place.
  IoTDevice copyWith({
    String? deviceName,
    DeviceStatus? status,
    List<String>? capabilities,
    Map<String, dynamic>? telemetry,
    String? localIp,
    String? authToken,
  }) {
    return IoTDevice(
      uniqueDeviceId: uniqueDeviceId,
      deviceName:     deviceName    ?? this.deviceName,
      status:         status        ?? this.status,
      capabilities:   capabilities  ?? this.capabilities,
      telemetry:      telemetry     ?? this.telemetry,
      localIp:        localIp       ?? this.localIp,
      authToken:      authToken     ?? this.authToken,
    );
  }

  @override
  String toString() =>
      'IoTDevice(id: $uniqueDeviceId, name: $deviceName, '
      'status: ${status.name}, caps: $capabilities)';

  // ── Private helpers ──────────────────────────────────────────────────────

  static DeviceStatus _parseStatus(String? raw) {
    switch (raw) {
      case 'online':       return DeviceStatus.online;
      case 'provisioning': return DeviceStatus.provisioning;
      default:             return DeviceStatus.offline;
    }
  }
}
