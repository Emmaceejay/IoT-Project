import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/smart_device.dart';
import 'device_manager.dart';
import 'ble_provisioning_service.dart';

/// Handles all device commissioning flows:
///
/// 1. **DSGV BLE provisioning** (`dsgv://provision?name=DSGVHub_XXXXXX`)
///    — Pushes Wi-Fi credentials to an un-provisioned ESP32 over Bluetooth.
///    The device reboots, connects to Wi-Fi, and announces itself via MQTT.
///    This flow requires no cloud; it works entirely over BLE.
///
/// 2. **QR short-code pairing** (`MT:XXXXX`)
///    — OS-native QR commissioning placeholder until the esp-matter
///    SDK and platform channels are integrated.
class DeviceCommissioningService {
  final Ref _ref;

  DeviceCommissioningService(this._ref);

  // ── DSGV BLE provisioning ─────────────────────────────────────────────────

  /// Streams BLE provisioning progress updates.
  Stream<ProvisioningStatus> provisionViaBle({
    required String deviceName,
    required String ssid,
    required String password,
    required String assignedName,
    String? deviceType,
    List<String>? capabilities,
    int? relayCount,
  }) async* {
    yield* BleProvisioningService.provision(
      deviceName: deviceName,
      ssid: ssid,
      password: password,
      deviceType: deviceType,
      capabilities: capabilities,
      relayCount: relayCount,
    );
  }

  // ── QR commissioning (OS native placeholder) ──────────────────────────────

  Future<DeviceCommissioningResult> commissionDevice({
    required String? qrCodeString,
    required String assignedName,
  }) async {
    try {
      // ── Stub: replace with real platform channel once SDK is linked ───────
      await Future.delayed(const Duration(seconds: 2));
      final assignedNodeId = _generateNodeId();
      // ─────────────────────────────────────────────────────────────────────

      final newDevice = SmartDevice(
        uniqueDeviceId: assignedNodeId,
        deviceName: assignedName,
        status: DeviceStatus.provisioning,
        capabilities: ['relay'],
        telemetry: {},
      );

      await _ref
          .read(deviceManagerProvider.notifier)
          .registerNewDevice(newDevice);

      return DeviceCommissioningResult(
        success: true,
        deviceId: assignedNodeId,
        message: 'Device "$assignedName" paired successfully!',
      );
    } catch (e) {
      return DeviceCommissioningResult(
        success: false,
        message: 'Commissioning failed: $e',
      );
    }
  }

  String _generateNodeId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'DSGV-NODE-$ts';
  }
}

class DeviceCommissioningResult {
  final bool success;
  final String? deviceId;
  final String message;

  const DeviceCommissioningResult({
    required this.success,
    this.deviceId,
    required this.message,
  });
}

final deviceCommissioningProvider = Provider<DeviceCommissioningService>((ref) {
  return DeviceCommissioningService(ref);
});
