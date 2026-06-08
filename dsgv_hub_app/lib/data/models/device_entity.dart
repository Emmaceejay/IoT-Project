import 'dart:convert';
import 'package:objectbox/objectbox.dart';
import '../../domain/models/iot_device.dart';

@Entity()
class DeviceEntity {
  @Id()
  int id = 0;

  /// Globally unique device identifier (MAC address (WiFi interface)).
  /// Replace-on-conflict acts as an upsert when provisioning the same device twice.
  @Unique(onConflict: ConflictStrategy.replace)
  @Index()
  late String uniqueDeviceId;

  late String deviceName;

  /// [DeviceStatus] enum stored as its `.name` string ('online', 'offline', etc.)
  late String statusName;

  /// JSON-encoded List<String> — avoids ObjectBox vector-type edge-cases.
  late String capabilitiesJson;

  /// JSON-encoded Map<String, dynamic> — ObjectBox does not support dynamic maps.
  late String telemetryJson;

  /// Optional LAN IP for direct HTTP transport (Tasmota-style).
  String? localIp;

  /// 32-char hex auth token received over BLE at first provisioning.
  /// Stored locally only — never transmitted over MQTT.
  String? authToken;

  // ── Conversions ───────────────────────────────────────────────────────────

  IoTDevice toDomain() => IoTDevice(
        uniqueDeviceId: uniqueDeviceId,
        deviceName: deviceName,
        status: DeviceStatus.offline, // always; real-time events (MQTT/mDNS) flip to online
        capabilities:
            List<String>.from(jsonDecode(capabilitiesJson) as List),
        telemetry: telemetryJson.isNotEmpty
            ? Map<String, dynamic>.from(jsonDecode(telemetryJson) as Map)
            : {},
        localIp: localIp,
        authToken: authToken,
      );

  static DeviceEntity fromDomain(IoTDevice d) => DeviceEntity()
    ..uniqueDeviceId = d.uniqueDeviceId
    ..deviceName = d.deviceName
    ..statusName = d.status.name
    ..capabilitiesJson = jsonEncode(d.capabilities)
    ..telemetryJson =
        d.telemetry.isNotEmpty ? jsonEncode(d.telemetry) : '{}'
    ..localIp = d.localIp
    ..authToken = d.authToken;
}
