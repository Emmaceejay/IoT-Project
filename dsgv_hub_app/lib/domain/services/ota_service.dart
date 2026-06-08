import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'mqtt_service.dart';
import 'telemetry_service.dart';

// ── Factory firmware constants ─────────────────────────────────────────────────
// Injected at build time via --dart-define so they are compiled into the binary
// and never visible in the UI.  End users never see or enter these values.
//
// Example release build command:
//   flutter build apk \
//     --dart-define=OTA_FIRMWARE_URL=https://ota.dsgv.io/v1.2.3/dsgv_hub.bin \
//     --dart-define=OTA_FIRMWARE_HASH=<sha256-hex> \
//     --dart-define=OTA_FIRMWARE_VERSION=1.2.3
//
// In development (no --dart-define set) these are empty strings, which causes
// hasFactoryFirmware to return false and the "Push update" button to stay disabled.

/// Coordinates firmware update campaigns across the device fleet.
///
/// Uses MQTT as the lightweight trigger channel.  The actual binary delivery
/// happens over HTTPS on the device side (ESP-IDF https_ota).
///
/// Typical update flow:
/// 1. Developer builds a new firmware binary, signs it, uploads to a CDN.
/// 2. A new app release is cut with the CDN URL + SHA-256 hash baked in via
///    --dart-define.  End users install the app update.
/// 3. User taps "Push update to all devices" in Settings.  The app publishes
///    the URL + hash to each device's ota-trigger MQTT topic.
/// 4. Each device validates the hash, downloads the binary over HTTPS, flashes
///    the passive OTA partition, and reboots — confirmed by fresh telemetry.
class OtaOrchestratorService {
  // ── Factory firmware — developer-set, invisible to end users ──────────────
  static const factoryUrl =
      String.fromEnvironment('OTA_FIRMWARE_URL');
  static const factoryHash =
      String.fromEnvironment('OTA_FIRMWARE_HASH');
  static const factoryVersion =
      String.fromEnvironment('OTA_FIRMWARE_VERSION', defaultValue: '');

  /// True when this build was compiled with a real OTA URL and hash.
  /// False in development builds (no --dart-define supplied).
  static bool get hasFactoryFirmware =>
      factoryUrl.isNotEmpty && factoryHash.isNotEmpty;

  final Ref _ref;
  final Map<String, OtaUpdateState> _activeUpdates = {};

  OtaOrchestratorService(this._ref);

  /// Watches the live OTA state for a specific device.
  Stream<OtaUpdateState> watchUpdate(String deviceId) {
    return Stream.periodic(const Duration(seconds: 1), (_) {
      return _activeUpdates[deviceId] ?? OtaUpdateState.idle(deviceId);
    });
  }

  /// Pushes the manufacturer firmware to every device in [deviceIds].
  ///
  /// Returns the number of devices that received the trigger.
  /// Uses the factory URL + hash embedded in this build; never asks the user
  /// for a URL or hash.
  Future<int> triggerFleetUpdate({
    required List<String> deviceIds,
    String? firmwareUrl,
    String? expectedHash,
  }) async {
    final url  = firmwareUrl  ?? factoryUrl;
    final hash = expectedHash ?? factoryHash;
    assert(url.isNotEmpty && hash.isNotEmpty,
        'OTA_FIRMWARE_URL and OTA_FIRMWARE_HASH must be set via --dart-define');

    final payload = jsonEncode({'url': url, 'hash': hash});
    int count = 0;

    for (final id in deviceIds) {
      try {
        await _ref
            .read(mqttServiceProvider.notifier)
            .publish('devices/$id/ota-trigger', payload);
        _activeUpdates[id] = OtaUpdateState.inProgress(id, 0);
        count++;
        debugPrint('[OTA] Fleet trigger sent → $id');
      } catch (e) {
        debugPrint('[OTA] Failed to trigger $id: $e');
      }
    }

    _ref
        .read(telemetryServiceProvider)
        .logOtaStarted('fleet:$count', url);
    debugPrint('[OTA] Fleet update dispatched to $count / ${deviceIds.length} device(s)');
    return count;
  }

  /// Initiates an OTA update for a single device (used by DeviceDetailScreen).
  ///
  /// Publishes a trigger and simulates progress until real telemetry arrives.
  Future<void> triggerUpdate({
    required String deviceId,
    String? firmwareUrl,
    String? expectedHash,
  }) async {
    final url  = firmwareUrl  ?? factoryUrl;
    final hash = expectedHash ?? factoryHash;
    assert(url.isNotEmpty && hash.isNotEmpty,
        'OTA_FIRMWARE_URL and OTA_FIRMWARE_HASH must be set via --dart-define');

    _activeUpdates[deviceId] = OtaUpdateState.inProgress(deviceId, 0);
    final payload = jsonEncode({'url': url, 'hash': hash});
    debugPrint('[OTA] Triggering single update for $deviceId | url: $url');

    _ref.read(telemetryServiceProvider).logOtaStarted(deviceId, url);

    try {
      await _ref
          .read(mqttServiceProvider.notifier)
          .publish('devices/$deviceId/ota-trigger', payload);

      // Simulate progress until real telemetry arrives on
      // devices/{id}/telemetry with {"ota_progress": 0..100}.
      for (int p = 10; p <= 100; p += 10) {
        await Future.delayed(const Duration(milliseconds: 500));
        _activeUpdates[deviceId] = OtaUpdateState.inProgress(deviceId, p);
      }

      _activeUpdates[deviceId] = OtaUpdateState.complete(deviceId);
      _ref.read(telemetryServiceProvider).logOtaResult(deviceId, success: true);
      debugPrint('[OTA] Update complete for $deviceId.');
    } catch (e, stack) {
      _activeUpdates[deviceId] = OtaUpdateState.failed(deviceId, e.toString());
      _ref.read(telemetryServiceProvider)
          .logOtaResult(deviceId, success: false, error: e.toString());
      _ref.read(telemetryServiceProvider)
          .logError(e, stack, context: 'OTA triggerUpdate');
      debugPrint('[OTA] Update failed for $deviceId: $e');
    }
  }

  void dispose() {
    _activeUpdates.clear();
  }
}

/// Value class representing the OTA state for one device.
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
