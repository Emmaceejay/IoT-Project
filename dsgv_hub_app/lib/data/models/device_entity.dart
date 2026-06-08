import 'dart:convert';
import 'package:objectbox/objectbox.dart';
import '../../domain/models/smart_device.dart';

@Entity()
class DeviceEntity {
  @Id()
  int id = 0;

  /// Globally unique device identifier (MAC address or Matter Node ID).
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

  /// User-assigned display name. Null = show auto-generated deviceName.
  /// Never overwritten by MQTT announce — only changed by explicit user action.
  String? customName;

  /// Power restore preference stored as its enum name: "off" | "restore" | "on".
  String powerRestoreModeStr = 'off';

  /// Model identifier matching the firmware manifest key, e.g. "1gang_switch".
  String deviceType = '';

  /// Firmware version last reported by the device, e.g. "1.0.0".
  String firmwareVersion = '';

  // ── Conversions ───────────────────────────────────────────────────────────

  SmartDevice toDomain() => SmartDevice(
        uniqueDeviceId: uniqueDeviceId,
        deviceName: deviceName,
        status: DeviceStatus.values.firstWhere(
          (s) => s.name == statusName,
          orElse: () => DeviceStatus.offline,
        ),
        capabilities:
            List<String>.from(jsonDecode(capabilitiesJson) as List),
        telemetry: telemetryJson.isNotEmpty
            ? Map<String, dynamic>.from(jsonDecode(telemetryJson) as Map)
            : {},
        localIp: localIp,
        authToken: authToken,
        customName: customName,
        powerRestoreMode: PowerRestoreMode.values.firstWhere(
          (m) => m.name == powerRestoreModeStr,
          orElse: () => PowerRestoreMode.off,
        ),
        deviceType: deviceType,
        firmwareVersion: firmwareVersion,
      );

  static DeviceEntity fromDomain(SmartDevice d) => DeviceEntity()
    ..uniqueDeviceId = d.uniqueDeviceId
    ..deviceName = d.deviceName
    ..statusName = d.status.name
    ..capabilitiesJson = jsonEncode(d.capabilities)
    ..telemetryJson =
        d.telemetry.isNotEmpty ? jsonEncode(d.telemetry) : '{}'
    ..localIp = d.localIp
    ..authToken = d.authToken
    ..customName = d.customName
    ..powerRestoreModeStr = d.powerRestoreMode.name
    ..deviceType = d.deviceType
    ..firmwareVersion = d.firmwareVersion;
}
