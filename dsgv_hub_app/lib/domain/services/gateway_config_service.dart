import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/mqtt_config.dart';

// ── Gateway base URL ──────────────────────────────────────────────────────────
// The deployed Cloudflare Worker URL — see ../../../../cloudflare_gateway/.
// `wrangler deploy` prints this after first deploy:
//   https://dsgv-hub-gateway.<your-subdomain>.workers.dev
const _kGatewayBase =
    'https://dsgv-hub-gateway.tectinkers.workers.dev';

// ── Service ───────────────────────────────────────────────────────────────────

/// Client for the DSGV Hub device-config gateway (cloudflare_gateway/).
///
/// All sensitive data stays server-side (never in MQTT).
/// Devices authenticate with their hardware-generated auth_token.
/// The app uses the same token (obtained via BLE provisioning) for all writes.
class GatewayConfigService {
  final http.Client _client;

  GatewayConfigService({http.Client? client})
      : _client = client ?? http.Client();

  /// Registers a newly provisioned device with the gateway.
  /// Called by the app immediately after BLE provisioning succeeds.
  /// Idempotent — safe to call multiple times for the same device.
  Future<void> registerDevice({
    required String deviceId,
    required String authToken,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$_kGatewayBase/registerDevice'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'device_id':   deviceId.toUpperCase(),
              'auth_token':  authToken.toUpperCase(),
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        debugPrint('[Gateway] registerDevice failed: ${res.statusCode} ${res.body}');
      } else {
        debugPrint('[Gateway] Device $deviceId registered successfully.');
      }
    } catch (e) {
      debugPrint('[Gateway] registerDevice error: $e');
    }
  }

  /// Pushes a new broker config to a single device via the gateway.
  /// The device will pick it up on its next reboot or config poll.
  Future<bool> updateDeviceConfig({
    required String deviceId,
    required String authToken,
    required MqttConfig config,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$_kGatewayBase/updateDeviceConfig'),
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
        debugPrint('[Gateway] Config updated for $deviceId → ${config.host}:${config.port}');
        return true;
      }
      debugPrint('[Gateway] updateDeviceConfig failed: ${res.statusCode} ${res.body}');
      return false;
    } catch (e) {
      debugPrint('[Gateway] updateDeviceConfig error: $e');
      return false;
    }
  }

  /// Resets a device's config back to the factory broker via the gateway.
  Future<bool> revertDeviceToFactory({
    required String deviceId,
    required String authToken,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$_kGatewayBase/revertDeviceToFactory'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'device_id':  deviceId.toUpperCase(),
              'auth_token': authToken.toUpperCase(),
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        debugPrint('[Gateway] Factory broker restored for $deviceId');
        return true;
      }
      debugPrint('[Gateway] revertDeviceToFactory failed: ${res.statusCode} ${res.body}');
      return false;
    } catch (e) {
      debugPrint('[Gateway] revertDeviceToFactory error: $e');
      return false;
    }
  }
}

final gatewayConfigServiceProvider = Provider<GatewayConfigService>((ref) {
  return GatewayConfigService();
});
