import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/mqtt_config.dart';

// ── Protocol constants ────────────────────────────────────────────────────────
// Must match DSGV_provisioning.c on the firmware side.

const _kServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const _kCredentialUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const _kStatusUuid = 'beb5483f-36e1-4688-b7f5-ea07361b26a8';

const _kDeviceNamePrefix = 'DSGVHub_';
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
    // Broker config is packed silently into the BLE payload so the device
    // connects to the right MQTT server from its first boot.  The caller
    // passes MqttConfig.factoryDefault (or the user's custom config if one
    // has been set) — the end user never sees or enters these values.
    MqttConfig? brokerConfig,
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

      // ── Step 5: Write credentials (+ device config + broker) ────────────────
      yield const ProvisioningStatus(ProvisioningStep.sendingCredentials);
      final Map<String, dynamic> payloadMap = {'ssid': ssid, 'password': password};
      if (deviceType != null)   payloadMap['device_type']  = deviceType;
      if (capabilities != null) payloadMap['capabilities'] = capabilities;
      if (relayCount != null)   payloadMap['relay_count']  = relayCount;

      // Silently include the MQTT broker config so the device connects to the
      // right server from its very first boot — no Firebase lookup needed.
      // The end user never sees or enters these values; they are manufacturer
      // constants (MqttConfig.factoryDefault) embedded in the app.
      final cfg = brokerConfig ?? MqttConfig.factoryDefault;
      if (cfg.isConfigured) {
        payloadMap['mqtt_host'] = cfg.host;
        payloadMap['mqtt_port'] = cfg.port;
        payloadMap['mqtt_tls']  = cfg.useTls ? 1 : 0;
        if (cfg.hasCredentials) {
          payloadMap['mqtt_user'] = cfg.username;
          payloadMap['mqtt_pass'] = cfg.password;
        }
      }

      final payload = jsonEncode(payloadMap);
      await credChar.write(utf8.encode(payload), withoutResponse: false);
      debugPrint('[BLE Prov] Credentials sent — SSID: $ssid | type: $deviceType | broker: ${cfg.host}');

      // ── Step 6: Race three signals for the device's final response ──────────
      // The firmware sends "success:<token>:<mac>" and then IMMEDIATELY reboots
      // to join Wi-Fi.  On many Android BLE stacks the reboot disconnect races
      // ahead of the GATT notification, causing the old .timeout().firstWhere()
      // to throw TimeoutException even though provisioning succeeded.
      //
      // Solution: use a single-completion Completer and listen to three
      // concurrent signals.  The first to fire wins; the rest are ignored.
      //
      //   Signal A — explicit BLE notification ("success:…" or "failed:…")
      //   Signal B — BLE disconnect (device rebooted = Wi-Fi join succeeded)
      //   Signal C — 30-second wall-clock deadline (genuine timeout / stuck)
      //
      // Signal B is safe to treat as success ONLY here, after credentials have
      // been written.  The firmware never reboots on a failed Wi-Fi join — it
      // stays up and returns "failed:<reason>" over BLE instead.
      yield const ProvisioningStatus(
        ProvisioningStep.waitingForDevice,
        'Waiting for device to connect to Wi-Fi…',
      );

      // The first of the three signals to fire completes this.
      final responseCompleter = Completer<String>();

      // Signal A — explicit firmware notification over BLE GATT
      final notifySub = statusUpdates.listen(
        (msg) {
          if (!responseCompleter.isCompleted &&
              (msg.startsWith('success:') || msg.startsWith('failed:'))) {
            responseCompleter.complete(msg);
          }
        },
        onError: (_) {}, // Suppress BLE stack errors on stream
        // onDone fires when the GATT stream closes (= BLE connection dropped).
        // Reaching here without a prior notification means the device rebooted.
        onDone: () {
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete('_disconnected');
          }
        },
      );

      // Signal B — connection-state watcher (fires faster than onDone on many
      // Android / iOS BLE driver implementations)
      final connSub = device.connectionState.listen((state) {
        if (!responseCompleter.isCompleted &&
            state == BluetoothConnectionState.disconnected) {
          responseCompleter.complete('_disconnected');
        }
      });

      // Signal C — hard 30-second deadline to avoid hanging the UI forever
      final timeoutTimer = Timer(const Duration(seconds: 30), () {
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete('_timeout');
        }
      });

      // Await the winner; always clean up the other two signals in finally.
      final String response;
      try {
        response = await responseCompleter.future;
      } finally {
        timeoutTimer.cancel();
        await notifySub.cancel();
        await connSub.cancel();
      }

      // Dispatch on whichever signal fired first
      if (response.startsWith('success:')) {
        // Format: "success:<32-hex-token>:<12-hex-wifi-mac>"
        final parts = response.split(':');
        yield ProvisioningStatus(
          ProvisioningStep.success,
          'Device provisioned! It will reboot and join your network.',
          parts.length >= 2 ? parts[1] : null,
          parts.length >= 3 ? parts[2] : null,
        );
      } else if (response.startsWith('failed:')) {
        final reason = response.replaceFirst('failed:', '').trim();
        yield ProvisioningStatus(
          ProvisioningStep.failed,
          reason.isNotEmpty
              ? reason
              : 'Device could not join the Wi-Fi network. Check the password and try again.',
        );
      } else if (response == '_disconnected') {
        // The device rebooted to join Wi-Fi — this is a success outcome.
        // authToken / provisionedDeviceId are null; the device will announce
        // itself over MQTT once it connects to the broker after its reboot.
        yield const ProvisioningStatus(
          ProvisioningStep.success,
          'Device rebooted to join your Wi-Fi.\nIt will appear on your dashboard shortly.',
        );
      } else {
        // '_timeout' — no signal from the device after 30 seconds
        yield const ProvisioningStatus(
          ProvisioningStep.failed,
          'No response from the device after 30 seconds.\n'
          'Check that your Wi-Fi password is correct and try again.',
        );
      }
    } catch (e) {
      yield ProvisioningStatus(
          ProvisioningStep.failed, 'Something went wrong: ${_friendly(e)}');
    } finally {
      // Disconnect cleanly on every path.  If the device already rebooted, the
      // call throws a "not connected" error — the inner try silences it.
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
