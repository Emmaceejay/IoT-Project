import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/matter_device.dart';
import 'device_manager.dart';
import 'ble_provisioning_service.dart';

/// Handles all device commissioning flows:
///
/// 1. **Nexus BLE provisioning** (`nexus://provision?name=NexusHub_XXXXXX`)
///    — Pushes Wi-Fi credentials to an un-provisioned ESP32 over Bluetooth.
///    The device reboots, connects to Wi-Fi, and announces itself via MQTT.
///    This flow requires no cloud; it works entirely over BLE.
///
/// 2. **Matter commissioning** (`MT:XXXXX`)
///    — OS-native Matter QR commissioning (placeholder until the esp-matter
///    SDK and flutter_matter platform channels are integrated).
class MatterCommissioningService {
  final Ref _ref;

  MatterCommissioningService(this._ref);

  // ── Nexus BLE provisioning ─────────────────────────────────────────────────

  /// Streams BLE provisioning progress updates.
  ///
  /// [deviceName] comes from the `name=` query parameter of the scanned
  /// `nexus://provision?name=NexusHub_XXXXXX` QR code.
  /// [assignedName] is the human-readable label the user entered in the app.
  ///
  /// After the device reboots and connects to Wi-Fi, it publishes an MQTT
  /// announce message. The existing MQTT handler in [DeviceManager] picks
  /// this up and registers the device automatically — no extra step needed.
  Stream<ProvisioningStatus> provisionViaBle({
    required String deviceName,
    required String ssid,
    required String password,
    required String assignedName,
    String? deviceType,
    List<String>? capabilities,
    int? relayCount,
  }) async* {
    // No pre-registration here. After the device reboots and joins Wi-Fi it
    // publishes an MQTT announce containing its real MAC-based ID, IP address,
    // and capabilities. The DeviceManager.handleAnnounce() pipeline picks that
    // up and registers it automatically — with the correct, permanent ID.
    // Pre-registering a placeholder would leave an orphaned entry because the
    // MQTT announce uses a different ID (MAC address, not the BLE device name).
    yield* BleProvisioningService.provision(
      deviceName: deviceName,
      ssid: ssid,
      password: password,
      deviceType: deviceType,
      capabilities: capabilities,
      relayCount: relayCount,
    );
  }

  // ── Matter commissioning (OS native) ──────────────────────────────────────

  /// Triggers Matter QR commissioning and registers the device.
  ///
  /// Currently uses a 2-second stub. Replace the stub block with:
  ///   `final result = await FlutterMatter.commission(setupCode: qrCodeString);`
  /// once the esp-matter SDK component and flutter_matter package are linked.
  Future<MatterCommissioningResult> commissionDevice({
    required String? qrCodeString,
    required String assignedName,
  }) async {
    try {
      // ── Stub: replace with real flutter_matter platform channel ──────────
      await Future.delayed(const Duration(seconds: 2));
      final assignedNodeId = _generateMockNodeId();
      // ─────────────────────────────────────────────────────────────────────

      final newDevice = MatterDevice(
        uniqueDeviceId: assignedNodeId,
        deviceName: assignedName,
        status: DeviceStatus.provisioning,
        capabilities: ['relay'],
        telemetry: {},
      );

      await _ref
          .read(deviceManagerProvider.notifier)
          .registerNewDevice(newDevice);

      return MatterCommissioningResult(
        success: true,
        deviceId: assignedNodeId,
        message: 'Device "$assignedName" paired successfully!',
      );
    } catch (e) {
      return MatterCommissioningResult(
        success: false,
        message: 'Commissioning failed: $e',
      );
    }
  }

  String _generateMockNodeId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'MATTER-NODE-$ts';
  }
}

class MatterCommissioningResult {
  final bool success;
  final String? deviceId;
  final String message;

  const MatterCommissioningResult({
    required this.success,
    this.deviceId,
    required this.message,
  });
}

final matterCommissioningProvider = Provider<MatterCommissioningService>((ref) {
  return MatterCommissioningService(ref);
});
