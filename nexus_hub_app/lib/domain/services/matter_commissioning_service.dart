import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/matter_device.dart';
import 'device_manager.dart';

/// Matter Commissioning Service
///
/// Handles bridging between the OS-native Matter commissioning flow
/// and our internal MQTT-based device registry.
///
/// On real devices, this calls flutter_matter platform channels to
/// trigger the iOS/Android native Matter pairing UI (QR scanning, BLE handshake).
/// On development/desktop, it stubs the flow so the team can test without hardware.
class MatterCommissioningService {
  final Ref _ref;

  MatterCommissioningService(this._ref);

  /// Triggers Matter QR commissioning and registers the device
  /// into the Nexus Hub ecosystem on success.
  Future<MatterCommissioningResult> commissionDevice({
    required String? qrCodeString, // 11-digit Matter setup code
    required String assignedName,
  }) async {
    try {
      // ── Step 1: Invoke OS Matter APIs ─────────────────────────────
      // In production, replace this with:
      //   final result = await FlutterMatter.commission(setupCode: qrCodeString);
      // For now we simulate a 2-second commissioning handshake.
      await Future.delayed(const Duration(seconds: 2));
      final assignedNodeId = _generateMockNodeId();

      // ── Step 2: Build our internal device record ───────────────────
      final newDevice = MatterDevice(
        uniqueDeviceId: assignedNodeId,
        deviceName: assignedName,
        status: DeviceStatus.provisioning,
        capabilities: ['relay'], // Default — device will update on first MQTT ping
        telemetry: {},
      );

      // ── Step 3: Register into DeviceManager (Isar + Riverpod) ────
      await _ref.read(deviceManagerProvider.notifier).registerNewDevice(newDevice);

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

  /// Generates a mock Node ID for dev — production uses real Matter Node ID
  String _generateMockNodeId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'MATTER-NODE-$timestamp';
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
