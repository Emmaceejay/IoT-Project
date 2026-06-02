import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// Local HTTP transport — Tasmota-compatible direct device control.
///
/// Used automatically when the phone is on the same WiFi network as a device
/// that has a known [localIp]. Tries the DSGV REST endpoint first, then
/// falls back to Tasmota cmnd syntax so off-the-shelf Tasmota firmware works
/// without any modification.
class LocalHttpService {
  static const _timeout = Duration(seconds: 3);

  /// True when the phone is connected to WiFi (required for local transport).
  Future<bool> isOnWifi() async {
    final results = await Connectivity().checkConnectivity();
    return results.contains(ConnectivityResult.wifi);
  }

  /// Probes [ip] to see if a device is reachable on the local network.
  Future<bool> isDeviceReachable(String ip) async {
    // Try DSGV status endpoint
    try {
      final res = await http
          .get(Uri.parse('http://$ip/api/status'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode < 500) return true;
    } catch (_) {}
    // Tasmota status fallback
    try {
      final res = await http
          .get(Uri.parse('http://$ip/cm?cmnd=Status'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Sends [capability] = [value] to the device at [deviceIp].
  /// Returns true if the command was acknowledged by the device.
  Future<bool> sendCommand(
    String deviceIp,
    String capability,
    dynamic value,
  ) async {
    // ── DSGV REST API (preferred) ──────────────────────────────────────────
    try {
      final body = jsonEncode({'capability': capability, 'value': value});
      final res = await http
          .post(
            Uri.parse('http://$deviceIp/api/cmd'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(_timeout);
      if (res.statusCode == 200) {
        debugPrint('[HTTP] ✓ DSGV cmd → $deviceIp $capability=$value');
        return true;
      }
    } catch (_) {}

    // ── Tasmota cmnd fallback ───────────────────────────────────────────────
    final tasmotaCmd = _toTasmotaCommand(capability, value);
    if (tasmotaCmd == null) {
      debugPrint('[HTTP] No Tasmota mapping for capability: $capability');
      return false;
    }
    try {
      final res = await http
          .get(Uri.parse(
              'http://$deviceIp/cm?cmnd=${Uri.encodeComponent(tasmotaCmd)}'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        debugPrint('[HTTP] ✓ Tasmota cmd → $deviceIp $tasmotaCmd');
        return true;
      }
    } catch (_) {}

    debugPrint('[HTTP] ✗ Command failed → $deviceIp $capability=$value');
    return false;
  }

  /// Fetches the current telemetry/state from a device.
  Future<Map<String, dynamic>?> getTelemetry(String deviceIp) async {
    try {
      final res = await http
          .get(Uri.parse('http://$deviceIp/api/status'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Maps DSGV command field names to Tasmota cmnd syntax.
  /// Only needed as a fallback for off-the-shelf Tasmota devices.
  /// DSGV firmware is always served by the REST path above; null here
  /// means Tasmota has no equivalent (HTTP fails, MQTT picks up instead).
  String? _toTasmotaCommand(String capability, dynamic value) {
    switch (capability) {
      case 'power':
        return value == true ? 'Power ON' : 'Power OFF';
      case 'power_2':
        return value == true ? 'Power2 ON' : 'Power2 OFF';
      case 'power_3':
        return value == true ? 'Power3 ON' : 'Power3 OFF';
      case 'power_4':
        return value == true ? 'Power4 ON' : 'Power4 OFF';
      case 'brightness':
        final pct = (value as num).clamp(0, 100).toInt();
        return 'Dimmer $pct';
      case 'color_temp':
        // Tasmota expects mired (153–500). DSGV uses Kelvin.
        final kelvin = (value as num).toDouble();
        final mired = (1000000 / kelvin).clamp(153, 500).round();
        return 'CT $mired';
      case 'target_temp':
        return 'TempTarget $value';
      // RGB and HVAC mode have no Tasmota equivalent — DSGV REST only.
      default:
        return null;
    }
  }
}

final localHttpServiceProvider = Provider<LocalHttpService>((ref) {
  return LocalHttpService();
});
