import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/mqtt_config.dart';

// ── Cloud Function base URL ───────────────────────────────────────────────────
// Replace YOUR_PROJECT_ID with your Firebase project ID.
// Find it at: Firebase Console → Project Settings → General → Project ID
const _kFunctionsBase =
    'https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net';

// ── Service ───────────────────────────────────────────────────────────────────

/// Secure gateway to Firebase for device broker configuration.
///
/// All sensitive data stays in Firebase (never in MQTT).
/// Devices authenticate with their hardware-generated auth_token.
/// The app uses the same token (obtained via BLE provisioning) for all writes.
class FirebaseConfigService {
  final http.Client _client;

  FirebaseConfigService({http.Client? client})
      : _client = client ?? http.Client();

  /// Registers a newly provisioned device in Firebase.
  /// Called by the app immediately after BLE provisioning succeeds.
  /// Idempotent — safe to call multiple times for the same device.
  Future<void> registerDevice({
    required String deviceId,
    required String authToken,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$_kFunctionsBase/registerDevice'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'device_id':   deviceId.toUpperCase(),
              'auth_token':  authToken.toUpperCase(),
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        debugPrint('[Firebase] registerDevice failed: ${res.statusCode} ${res.body}');
      } else {
        debugPrint('[Firebase] Device $deviceId registered successfully.');
      }
    } catch (e) {
      debugPrint('[Firebase] registerDevice error: $e');
    }
  }

  /// Pushes a new broker config to a single device in Firebase.
  /// The device will pick it up on its next reboot or config poll.
  Future<bool> updateDeviceConfig({
    required String deviceId,
    required String authToken,
    required MqttConfig config,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$_kFunctionsBase/updateDeviceConfig'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'device_id':       deviceId.toUpperCase(),
              'auth_token':      authToken.toUpperCase(),
              'broker_host':     config.host,
              'broker_port':     config.port,
              'broker_tls':      config.useTls,
              'broker_username': config.username,
              'broker_password': config.password,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        debugPrint('[Firebase] Config updated for $deviceId → ${config.host}:${config.port}');
        return true;
      }
      debugPrint('[Firebase] updateDeviceConfig failed: ${res.statusCode} ${res.body}');
      return false;
    } catch (e) {
      debugPrint('[Firebase] updateDeviceConfig error: $e');
      return false;
    }
  }

  /// Resets a device's config back to the factory broker in Firebase.
  Future<bool> revertDeviceToFactory({
    required String deviceId,
    required String authToken,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$_kFunctionsBase/revertDeviceToFactory'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'device_id':  deviceId.toUpperCase(),
              'auth_token': authToken.toUpperCase(),
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        debugPrint('[Firebase] Factory broker restored for $deviceId');
        return true;
      }
      debugPrint('[Firebase] revertDeviceToFactory failed: ${res.statusCode} ${res.body}');
      return false;
    } catch (e) {
      debugPrint('[Firebase] revertDeviceToFactory error: $e');
      return false;
    }
  }
}

final firebaseConfigServiceProvider = Provider<FirebaseConfigService>((ref) {
  return FirebaseConfigService();
});
