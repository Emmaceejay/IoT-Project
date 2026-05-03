import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// OTA Orchestrator Service
///
/// Coordinates firmware update campaigns across the device fleet.
/// Uses MQTT as the orchestration channel (lightweight trigger)
/// and HTTPS as the actual binary delivery mechanism.
///
/// Flow:
/// 1. Developer uploads signed .bin to S3/GCS.
/// 2. This service sends a Pre-Signed URL via MQTT to target device.
/// 3. Device validates signature, fetches binary over HTTPS, flashes dual-bank.
/// 4. Device reboots and re-publishes telemetry — OTA confirmed.
class OtaOrchestratorService {
  // TODO: Inject MqttConnectivityService for real pub/sub
  final Map<String, OtaUpdateState> _activeUpdates = {};

  Stream<OtaUpdateState> watchUpdate(String deviceId) {
    return Stream.periodic(const Duration(seconds: 1), (i) {
      return _activeUpdates[deviceId] ?? OtaUpdateState.idle(deviceId);
    });
  }

  /// Initiates an OTA campaign for a given device.
  Future<void> triggerUpdate({
    required String deviceId,
    required String firmwareUrl,  // Pre-Signed HTTPS URL to signed binary
    required String expectedHash, // SHA256 of the binary for on-device validation
  }) async {
    _activeUpdates[deviceId] = OtaUpdateState.inProgress(deviceId, 0);

    // In production: publish to 'devices/{deviceId}/ota-trigger'
    // with payload: {"url": firmwareUrl, "hash": expectedHash}
    final payload = '{"url":"$firmwareUrl","hash":"$expectedHash"}';
    debugPrint('[OTA] Triggering update for $deviceId | payload: $payload');

    // Simulate download/flash progress
    for (int progress = 0; progress <= 100; progress += 10) {
      await Future.delayed(const Duration(milliseconds: 500));
      _activeUpdates[deviceId] = OtaUpdateState.inProgress(deviceId, progress);
    }

    _activeUpdates[deviceId] = OtaUpdateState.complete(deviceId);
    debugPrint('[OTA] Update complete for $deviceId.');
  }

  void dispose() {
    _activeUpdates.clear();
  }
}

/// Value class representing OTA state for a specific device.
class OtaUpdateState {
  final String deviceId;
  final OtaStatus status;
  final int progressPercent;
  final String? errorMessage;

  const OtaUpdateState._({
    required this.deviceId,
    required this.status,
    this.progressPercent = 0,
    this.errorMessage,
  });

  factory OtaUpdateState.idle(String id) =>
      OtaUpdateState._(deviceId: id, status: OtaStatus.idle);
  factory OtaUpdateState.inProgress(String id, int progress) =>
      OtaUpdateState._(deviceId: id, status: OtaStatus.inProgress, progressPercent: progress);
  factory OtaUpdateState.complete(String id) =>
      OtaUpdateState._(deviceId: id, status: OtaStatus.complete, progressPercent: 100);
  factory OtaUpdateState.failed(String id, String msg) =>
      OtaUpdateState._(deviceId: id, status: OtaStatus.failed, errorMessage: msg);
}

enum OtaStatus { idle, inProgress, complete, failed }

final otaServiceProvider = Provider<OtaOrchestratorService>((ref) {
  final service = OtaOrchestratorService();
  ref.onDispose(service.dispose);
  return service;
});

// ignore: non_constant_identifier_names
void debugPrint(String message) {
  // ignore: avoid_print
  print(message);
}
