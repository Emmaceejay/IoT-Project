import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:wifi_scan/wifi_scan.dart';

enum WifiApProvisionStatus { sending, success, failed }

class WifiApProvisionResult {
  final WifiApProvisionStatus status;
  final String? message;
  final String? authToken;
  final String? deviceId;
  final bool isTerminal;

  const WifiApProvisionResult({
    required this.status,
    this.message,
    this.authToken,
    this.deviceId,
    this.isTerminal = false,
  });
}

class WifiApProvisioningService {
  static const _appHeaders = {
    'X-DSGV-Client': 'DSGVHub-App',
    'Content-Type': 'application/json',
  };
  static const _deviceBase = 'http://192.168.4.1';

  static Future<List<WiFiAccessPoint>> scanForDeviceAPs() async {
    try {
      final canStart = await WifiScan.instance.canStartScan(askPermissions: false);
      if (canStart == CanStartScan.yes) {
        await WifiScan.instance.startScan();
      }
      final results = await WifiScan.instance.getScannedResults(
        askPermissions: false,
      );
      return results.where((r) => r.ssid.startsWith('DSGV_SETUP_')).toList()
        ..sort((a, b) => b.level.compareTo(a.level));
    } catch (_) {
      return [];
    }
  }

  static Future<bool> pingOnce() async {
    try {
      final res = await http
          .get(Uri.parse('$_deviceBase/provision/ping'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Stream<WifiApProvisionResult> provision({
    required String homeSsid,
    required String homePassword,
    required String deviceType,
    required List<String> capabilities,
    required int relayCount,
  }) async* {
    yield const WifiApProvisionResult(
      status: WifiApProvisionStatus.sending,
      message: 'Sending credentials to device…',
    );

    try {
      final res = await http
          .post(
            Uri.parse('$_deviceBase/provision'),
            headers: _appHeaders,
            body: jsonEncode({
              'ssid': homeSsid,
              'password': homePassword,
              'device_type': deviceType,
              'capabilities': capabilities,
              'relay_count': relayCount,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        yield WifiApProvisionResult(
          status: WifiApProvisionStatus.success,
          message:
              'Device provisioned! It will now connect to your home Wi-Fi.\n\n'
              'Please reconnect your phone to your home network, '
              'then return to the app.',
          authToken: data['auth_token'] as String?,
          deviceId: data['device_id'] as String?,
          isTerminal: true,
        );
      } else {
        yield WifiApProvisionResult(
          status: WifiApProvisionStatus.failed,
          message: 'Device returned status ${res.statusCode}. Please try again.',
          isTerminal: true,
        );
      }
    } catch (_) {
      yield const WifiApProvisionResult(
        status: WifiApProvisionStatus.failed,
        message:
            'Could not reach device. Make sure your phone is still connected '
            'to the device Wi-Fi network.',
        isTerminal: true,
      );
    }
  }
}
