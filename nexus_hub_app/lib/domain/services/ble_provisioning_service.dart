import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// ── Protocol constants ────────────────────────────────────────────────────────
// Must match nexus_provisioning.c on the firmware side.

const _kServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const _kCredentialUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const _kStatusUuid = 'beb5483f-36e1-4688-b7f5-ea07361b26a8';

const _kDeviceNamePrefix = 'NexusHub_';
const _kScanTimeout = Duration(seconds: 20);
const _kConnectTimeout = Duration(seconds: 15);

// ── Progress model ────────────────────────────────────────────────────────────

enum ProvisioningStep {
  requestingPermissions,
  scanningForDevice,
  connecting,
  discoveringServices,
  sendingCredentials,
  waitingForDevice,
  success,
  failed,
}

class ProvisioningStatus {
  final ProvisioningStep step;
  final String? message;

  const ProvisioningStatus(this.step, [this.message]);

  bool get isTerminal =>
      step == ProvisioningStep.success || step == ProvisioningStep.failed;
}

// ── Service ───────────────────────────────────────────────────────────────────

/// Provisions an unprovisioned Nexus Hub ESP32 device with Wi-Fi credentials
/// over BLE using a custom GATT service.
///
/// Typical call sequence:
/// ```dart
/// final stream = BleProvisioningService.provision(
///   deviceName: 'NexusHub_A1B2C3',
///   ssid: 'HomeWifi',
///   password: 'secret',
/// );
/// await for (final status in stream) {
///   // update UI
///   if (status.isTerminal) break;
/// }
/// ```
class BleProvisioningService {
  /// Streams provisioning progress updates.
  /// Terminates (completes) after emitting [ProvisioningStep.success] or
  /// [ProvisioningStep.failed].
  ///
  /// [deviceName] is the BLE device name extracted from the QR code
  /// (`NexusHub_XXXXXX`). If null, the scan picks the first matching device.
  static Stream<ProvisioningStatus> provision({
    required String ssid,
    required String password,
    String? deviceName,
    String? deviceType,
    List<String>? capabilities,
    int? relayCount,
  }) async* {
    BluetoothDevice? device;

    // ── Step 1: Permissions ──────────────────────────────────────────────────
    yield const ProvisioningStatus(ProvisioningStep.requestingPermissions);
    try {
      await _ensurePermissions();
    } catch (e) {
      yield const ProvisioningStatus(ProvisioningStep.failed,
          'Bluetooth permissions denied. Enable them in system settings.');
      return;
    }

    if (!await FlutterBluePlus.isSupported) {
      yield const ProvisioningStatus(
          ProvisioningStep.failed, 'Bluetooth is not supported on this device.');
      return;
    }

    // ── Step 2: Scan ─────────────────────────────────────────────────────────
    yield ProvisioningStatus(
      ProvisioningStep.scanningForDevice,
      deviceName != null ? 'Looking for $deviceName…' : 'Scanning for Nexus devices…',
    );

    try {
      device = await _scanForDevice(deviceName);
    } catch (e) {
      yield ProvisioningStatus(
        ProvisioningStep.failed,
        deviceName != null
            ? 'Device $deviceName not found. Make sure it is powered on and within range.'
            : 'No Nexus devices found within range.',
      );
      return;
    }

    // ── Step 3: Connect ──────────────────────────────────────────────────────
    yield ProvisioningStatus(
      ProvisioningStep.connecting,
      'Connecting to ${device.platformName}…',
    );
    try {
      await device.connect(timeout: _kConnectTimeout);
    } catch (e) {
      yield ProvisioningStatus(
          ProvisioningStep.failed, 'Failed to connect: ${_friendly(e)}');
      return;
    }

    try {
      // ── Step 4: Discover services ──────────────────────────────────────────
      yield const ProvisioningStatus(ProvisioningStep.discoveringServices);
      final services = await device.discoverServices();

      final provSvc = services
          .where((s) => s.serviceUuid == Guid(_kServiceUuid))
          .firstOrNull;
      if (provSvc == null) {
        yield const ProvisioningStatus(
          ProvisioningStep.failed,
          'Provisioning service not found. Make sure this device has Nexus firmware.',
        );
        return;
      }

      final credChar = provSvc.characteristics
          .where((c) => c.characteristicUuid == Guid(_kCredentialUuid))
          .firstOrNull;
      final statusChar = provSvc.characteristics
          .where((c) => c.characteristicUuid == Guid(_kStatusUuid))
          .firstOrNull;

      if (credChar == null || statusChar == null) {
        yield const ProvisioningStatus(
          ProvisioningStep.failed,
          'Firmware GATT characteristics not found. Update the device firmware.',
        );
        return;
      }

      // Subscribe to status notifications before writing credentials so we
      // don't miss the "success" notification that arrives right after the write.
      await statusChar.setNotifyValue(true);
      final statusUpdates = statusChar.onValueReceived
          .map((bytes) => utf8.decode(bytes, allowMalformed: true));

      // ── Step 5: Write credentials (+ optional device config) ──────────────
      yield const ProvisioningStatus(ProvisioningStep.sendingCredentials);
      final Map<String, dynamic> payloadMap = {'ssid': ssid, 'password': password};
      if (deviceType != null)   payloadMap['device_type']  = deviceType;
      if (capabilities != null) payloadMap['capabilities'] = capabilities;
      if (relayCount != null)   payloadMap['relay_count']  = relayCount;
      final payload = jsonEncode(payloadMap);
      await credChar.write(utf8.encode(payload), withoutResponse: false);
      debugPrint('[BLE Prov] Credentials sent for SSID: $ssid (type=$deviceType relays=$relayCount)');

      // ── Step 6: Wait for device confirmation ──────────────────────────────
      yield const ProvisioningStatus(
        ProvisioningStep.waitingForDevice,
        'Waiting for device to connect to Wi-Fi…',
      );

      final deviceStatus = await statusUpdates
          .timeout(const Duration(seconds: 15))
          .firstWhere((s) => s == 'success' || s.startsWith('failed:'));

      if (deviceStatus == 'success') {
        yield const ProvisioningStatus(
          ProvisioningStep.success,
          'Device provisioned! It will reboot and join your network.',
        );
      } else {
        final reason = deviceStatus.replaceFirst('failed:', '');
        yield ProvisioningStatus(
          ProvisioningStep.failed,
          'Device rejected credentials: $reason',
        );
      }
    } catch (e) {
      yield ProvisioningStatus(
          ProvisioningStep.failed, 'Provisioning error: ${_friendly(e)}');
    } finally {
      // device is always non-null here: any earlier failure path calls return.
      // Device reboots on success, but we disconnect cleanly on all paths.
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static Future<void> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // Required for BLE scan on Android < 12
    ].request();

    // Scan and connect are the minimum requirements
    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    if (!scanOk || !connectOk) {
      throw Exception('BLE permissions not granted');
    }
  }

  static Future<BluetoothDevice> _scanForDevice(String? targetName) async {
    final completer = Completer<BluetoothDevice>();

    // Check already-connected devices first — avoids a full scan when the app
    // reconnects to the same device within the same session.
    for (final d in FlutterBluePlus.connectedDevices) {
      if (_isNexusDevice(d.platformName, targetName)) return d;
    }

    // Subscribe BEFORE starting the scan so no result is ever missed.
    // flutter_blue_plus emits cumulative results; guard with !isCompleted.
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (_isNexusDevice(r.device.platformName, targetName) &&
            !completer.isCompleted) {
          completer.complete(r.device);
        }
      }
    });

    try {
      // timeout on startScan stops BLE scanning; the completer timeout below
      // handles the case where scanning stops without finding the device.
      await FlutterBluePlus.startScan(timeout: _kScanTimeout);
      return await completer.future.timeout(_kScanTimeout);
    } on TimeoutException {
      throw Exception('Scan timed out — device not found');
    } finally {
      await sub.cancel();
      // stopScan is idempotent; safe to call even if scan already finished.
      await FlutterBluePlus.stopScan();
    }
  }

  static bool _isNexusDevice(String name, String? target) {
    if (target != null) return name == target;
    return name.startsWith(_kDeviceNamePrefix);
  }

  static String _friendly(dynamic e) {
    final msg = e.toString();
    if (msg.contains('timeout')) return 'Connection timed out';
    if (msg.contains('permission')) return 'Permission denied';
    if (msg.contains('disconnect')) return 'Device disconnected unexpectedly';
    return msg;
  }
}
