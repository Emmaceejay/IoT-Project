import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// ── Protocol constants ────────────────────────────────────────────────────────
// Must match DSGV_provisioning.c on the firmware side.

const _kServiceUuid   = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const _kCredentialUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const _kStatusUuid    = 'beb5483f-36e1-4688-b7f5-ea07361b26a8';
// Wi-Fi scan results characteristic — READ only, populated on device boot.
// Returns a JSON array: [{"ssid":"Network","rssi":-45}, ...]
const _kWifiScanUuid   = 'beb5483d-36e1-4688-b7f5-ea07361b26a8';
// Device identity characteristic — READ only.
// Returns: {"device_type":"Switch","capabilities":["relay"],"relay_count":1}
const _kDeviceInfoUuid = 'beb5483c-36e1-4688-b7f5-ea07361b26a8';

const _kDeviceNamePrefix = 'DSGVHub_';
const _kScanTimeout = Duration(seconds: 20);
const _kConnectTimeout = Duration(seconds: 15);

// ── Wi-Fi network model ───────────────────────────────────────────────────────

class WifiNetwork {
  final String ssid;
  final int rssi;

  const WifiNetwork({required this.ssid, required this.rssi});

  factory WifiNetwork.fromJson(Map<String, dynamic> json) => WifiNetwork(
        ssid: json['ssid'] as String,
        rssi: (json['rssi'] as num).toInt(),
      );

  /// Signal level 0–3 (weak → excellent) for icon/colour selection.
  int get signalLevel {
    if (rssi >= -55) return 3;
    if (rssi >= -67) return 2;
    if (rssi >= -78) return 1;
    return 0;
  }
}

// ── Device identity model ─────────────────────────────────────────────────────

/// Everything the app needs before provisioning starts, fetched in a single
/// BLE connection so the user never has to pick a device type manually.
class ProvisioningDeviceInfo {
  final List<WifiNetwork> networks;
  final String deviceType;
  final List<String> capabilities;
  final int relayCount;

  const ProvisioningDeviceInfo({
    required this.networks,
    required this.deviceType,
    required this.capabilities,
    required this.relayCount,
  });

  /// Human-readable label derived from the device's own capabilities.
  String get label {
    if (capabilities.contains('rgb'))                              return 'RGB Light';
    if (capabilities.contains('brightness') &&
        capabilities.contains('color_temp'))                       return 'Colour Temp Light';
    if (capabilities.contains('brightness'))                       return 'Dimmable Light';
    if (capabilities.contains('hvac_mode'))                        return 'Thermostat';
    if (capabilities.contains('motion'))                           return 'Motion Sensor';
    if (capabilities.contains('contact'))                          return 'Contact Sensor';
    if (capabilities.contains('temperature'))                      return 'Temperature Sensor';
    if (relayCount > 1)                                            return '$relayCount-Gang Switch';
    if (capabilities.contains('relay'))                            return '1-Gang Switch';
    return deviceType;
  }

  IconData get icon {
    if (capabilities.contains('rgb') || capabilities.contains('brightness')) {
      return Icons.light_mode;
    }
    if (capabilities.contains('hvac_mode')) return Icons.thermostat;
    if (capabilities.contains('motion'))    return Icons.sensors;
    if (capabilities.contains('contact'))   return Icons.sensor_door;
    return Icons.power; // relay / switch
  }
}

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

  // Populated only on success — the 32-char hex auth token and device's WiFi MAC
  // (= MQTT device_id). Both extracted from the firmware's BLE status response.
  final String? authToken;
  final String? provisionedDeviceId;

  const ProvisioningStatus(this.step, [this.message,
      this.authToken, this.provisionedDeviceId]);

  bool get isTerminal =>
      step == ProvisioningStep.success || step == ProvisioningStep.failed;
}

// ── Service ───────────────────────────────────────────────────────────────────

/// Provisions an unprovisioned DSGV Hub ESP32 device with Wi-Fi credentials
/// over BLE using a custom GATT service.
///
/// Typical call sequence:
/// ```dart
/// final stream = BleProvisioningService.provision(
///   deviceName: 'DSGVHub_A1B2C3',
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
  /// (`DSGVHub_XXXXXX`). If null, the scan picks the first matching device.
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
      deviceName != null ? 'Looking for $deviceName…' : 'Scanning for DSGV devices…',
    );

    try {
      device = await _scanForDevice(deviceName);
    } catch (e) {
      yield ProvisioningStatus(
        ProvisioningStep.failed,
        deviceName != null
            ? 'Device $deviceName not found. Make sure it is powered on and within range.'
            : 'No DSGV devices found within range.',
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
          'Provisioning service not found. Make sure this device has DSGV firmware.',
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
          .firstWhere((s) => s.startsWith('success:') || s.startsWith('failed:'));

      if (deviceStatus.startsWith('success:')) {
        // Format: "success:<32-hex-token>:<12-hex-wifi-mac>"
        final parts = deviceStatus.split(':');
        final authToken       = parts.length >= 2 ? parts[1] : null;
        final provisionedId   = parts.length >= 3 ? parts[2] : null;
        yield ProvisioningStatus(
          ProvisioningStep.success,
          'Device provisioned! It will reboot and join your network.',
          authToken,
          provisionedId,
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

  // ── Pre-provisioning data fetch ──────────────────────────────────────────────

  /// Opens a single BLE connection to [deviceName], reads the device identity
  /// and nearby Wi-Fi networks in parallel, then disconnects.
  ///
  /// Never throws — returns sensible defaults on any failure so the screen
  /// can always fall back to manual entry.
  static Future<ProvisioningDeviceInfo> fetchProvisioningData(
      String deviceName) async {
    BluetoothDevice? device;
    try {
      await _ensurePermissions();
      device = await _scanForDevice(deviceName);
      await device.connect(timeout: _kConnectTimeout);

      // Negotiate a larger MTU so both JSON payloads fit in a single read each.
      try { await device.requestMtu(512); } catch (_) {}

      final services = await device.discoverServices();
      final provSvc = services
          .where((s) => s.serviceUuid == Guid(_kServiceUuid))
          .firstOrNull;
      if (provSvc == null) return _emptyDeviceInfo();

      // Read both characteristics concurrently.
      final wifiChar = provSvc.characteristics
          .where((c) => c.characteristicUuid == Guid(_kWifiScanUuid))
          .firstOrNull;
      final infoChar = provSvc.characteristics
          .where((c) => c.characteristicUuid == Guid(_kDeviceInfoUuid))
          .firstOrNull;

      final results = await Future.wait([
        wifiChar != null ? wifiChar.read() : Future.value(<int>[]),
        infoChar != null ? infoChar.read() : Future.value(<int>[]),
      ]);

      final networks  = _parseNetworks(utf8.decode(results[0], allowMalformed: true));
      final identity  = _parseDeviceInfo(utf8.decode(results[1], allowMalformed: true));

      debugPrint('[BLE Prov] device info: ${utf8.decode(results[1])}');
      debugPrint('[BLE Prov] wifi scan:   ${utf8.decode(results[0])}');

      return ProvisioningDeviceInfo(
        networks:     networks,
        deviceType:   identity['device_type'] as String? ?? 'Unknown',
        capabilities: (identity['capabilities'] as List<dynamic>?)
                          ?.map((e) => e.toString())
                          .toList() ?? [],
        relayCount:   (identity['relay_count'] as num?)?.toInt() ?? 1,
      );
    } catch (e) {
      debugPrint('[BLE Prov] fetchProvisioningData failed: $e');
      return _emptyDeviceInfo();
    } finally {
      try { await device?.disconnect(); } catch (_) {}
    }
  }

  static List<WifiNetwork> _parseNetworks(String json) {
    try {
      final raw = jsonDecode(json) as List<dynamic>;
      return raw.map((e) => WifiNetwork.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static Map<String, dynamic> _parseDeviceInfo(String json) {
    try { return jsonDecode(json) as Map<String, dynamic>; }
    catch (_) { return {}; }
  }

  static ProvisioningDeviceInfo _emptyDeviceInfo() =>
      const ProvisioningDeviceInfo(
        networks: [], deviceType: 'Unknown', capabilities: [], relayCount: 1);


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
      if (_isDSGVDevice(d.platformName, targetName)) return d;
    }

    // Subscribe BEFORE starting the scan so no result is ever missed.
    // flutter_blue_plus emits cumulative results; guard with !isCompleted.
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (_isDSGVDevice(r.device.platformName, targetName) &&
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

  static bool _isDSGVDevice(String name, String? target) {
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
