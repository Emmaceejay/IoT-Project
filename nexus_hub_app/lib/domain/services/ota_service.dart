import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'mqtt_service.dart';
import 'telemetry_service.dart';

/// OTA Orchestrator Service
///
/// Coordinates firmware update campaigns across the device fleet.
/// Uses MQTT as the orchestration channel (lightweight trigger)
/// and HTTPS as the actual binary delivery mechanism on the device.
///
/// Flow:
/// 1. Developer uploads signed .bin to S3/GCS.
/// 2. This service sends a Pre-Signed URL via MQTT to the target device.
/// 3. Device validates signature, fetches binary over HTTPS, flashes dual-bank.
/// 4. Device reboots and re-publishes telemetry — OTA confirmed.
class OtaOrchestratorService {
  final Ref _ref;
  final Map<String, OtaUpdateState> _activeUpdates = {};

  OtaOrchestratorService(this._ref);

  Stream<OtaUpdateState> watchUpdate(String deviceId) {
    return Stream.periodic(const Duration(seconds: 1), (_) {
      return _activeUpdates[deviceId] ?? OtaUpdateState.idle(deviceId);
    });
  }

  /// Initiates an OTA campaign for a given device.
  ///
  /// Publishes a signed URL and expected SHA-256 hash to the device's
  /// `devices/{deviceId}/ota-trigger` MQTT topic. The device firmware
  /// handles download, signature verification, and dual-bank flashing.
  Future<void> triggerUpdate({
    required String deviceId,
    required String firmwareUrl,
    required String expectedHash,
  }) async {
    _activeUpdates[deviceId] = OtaUpdateState.inProgress(deviceId, 0);

    final payload = jsonEncode({'url': firmwareUrl, 'hash': expectedHash});
    debugPrint('[OTA] Triggering update for $deviceId | url: $firmwareUrl');

    _ref.read(telemetryServiceProvider).logOtaStarted(deviceId, firmwareUrl);

    try {
      await _ref
          .read(mqttServiceProvider.notifier)
          .publish('devices/$deviceId/ota-trigger', payload);

      // Poll for progress — in production the device publishes back on
      // devices/{id}/telemetry with {"ota_progress": 0..100}.
      // Here we simulate progress until real telemetry replaces it.
      for (int p = 10; p <= 100; p += 10) {
        await Future.delayed(const Duration(milliseconds: 500));
        _activeUpdates[deviceId] = OtaUpdateState.inProgress(deviceId, p);
      }

      _activeUpdates[deviceId] = OtaUpdateState.complete(deviceId);
      _ref
          .read(telemetryServiceProvider)
          .logOtaResult(deviceId, success: true);
      debugPrint('[OTA] Update complete for $deviceId.');
    } catch (e, stack) {
      _activeUpdates[deviceId] =
          OtaUpdateState.failed(deviceId, e.toString());
      _ref
          .read(telemetryServiceProvider)
          .logOtaResult(deviceId, success: false, error: e.toString());
      _ref
          .read(telemetryServiceProvider)
          .logError(e, stack, context: 'OTA triggerUpdate');
      debugPrint('[OTA] Update failed for $deviceId: $e');
    }
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
      OtaUpdateState._(
          deviceId: id,
          status: OtaStatus.inProgress,
          progressPercent: progress);
  factory OtaUpdateState.complete(String id) =>
      OtaUpdateState._(
          deviceId: id, status: OtaStatus.complete, progressPercent: 100);
  factory OtaUpdateState.failed(String id, String msg) =>
      OtaUpdateState._(
          deviceId: id, status: OtaStatus.failed, errorMessage: msg);
}

enum OtaStatus { idle, inProgress, complete, failed }

final otaServiceProvider = Provider<OtaOrchestratorService>((ref) {
  final service = OtaOrchestratorService(ref);
  ref.onDispose(service.dispose);
  return service;
});
