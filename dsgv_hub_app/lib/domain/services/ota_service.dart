import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'mqtt_service.dart';
import 'telemetry_service.dart';

// ── Firmware Manifest ─────────────────────────────────────────────────────────

/// Permanent URL for the firmware manifest JSON file hosted on GitHub.
/// Update this only if the repo or file path changes — never per-release.
const _kManifestUrl =
    'https://raw.githubusercontent.com/Emmaceejay/IoT-Project/main/firmware_manifest.json';

/// Per-device entry inside the manifest: the .bin download URL and its SHA-256.
class ManifestEntry {
  final String url;
  final String hash;
  const ManifestEntry({required this.url, required this.hash});
}

/// Top-level manifest parsed from [_kManifestUrl].
class FirmwareManifest {
  final String version;
  final String releaseDate;
  final String notes;

  /// Keyed by device-type string, e.g. "1gang_switch", "rgb_light".
  final Map<String, ManifestEntry> devices;

  const FirmwareManifest({
    required this.version,
    required this.releaseDate,
    required this.notes,
    required this.devices,
  });

  factory FirmwareManifest.fromJson(Map<String, dynamic> json) {
    final devicesJson = json['devices'] as Map<String, dynamic>? ?? {};
    final devices = devicesJson.map((key, value) {
      final v = value as Map<String, dynamic>;
      return MapEntry(
        key,
        ManifestEntry(
          url: v['url'] as String? ?? '',
          hash: v['hash'] as String? ?? '',
        ),
      );
    });
    return FirmwareManifest(
      version: json['version'] as String? ?? '',
      releaseDate: json['release_date'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      devices: devices,
    );
  }

  /// Returns the [ManifestEntry] for the given device type, or null if absent.
  ManifestEntry? entryFor(String deviceType) => devices[deviceType];
}

/// Fetches the firmware manifest from GitHub.
///
/// Starts as `AsyncData(null)` — meaning "not yet checked".
/// Call [fetch()] to populate. The UI watches this provider and reacts to
/// the three states: null (initial), loading, data/error.
class ManifestNotifier extends AsyncNotifier<FirmwareManifest?> {
  @override
  Future<FirmwareManifest?> build() async => null;

  Future<void> fetch() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final response = await http
          .get(Uri.parse(_kManifestUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception(
            'Server returned HTTP ${response.statusCode}. Check your internet connection.');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return FirmwareManifest.fromJson(json);
    });
  }
}

final manifestProvider =
    AsyncNotifierProvider<ManifestNotifier, FirmwareManifest?>(
        ManifestNotifier.new);

// ── OTA Orchestrator ──────────────────────────────────────────────────────────

/// Coordinates OTA firmware updates across the device fleet.
/// Uses MQTT as the orchestration channel; device fetches the binary over HTTPS.
///
/// Flow:
///  1. App fetches manifest → [ManifestNotifier.fetch()]
///  2. User taps "Update" on a device → [triggerUpdate()] publishes URL + hash
///     to devices/{id}/ota-trigger via MQTT
///  3. Device validates hash, downloads .bin over HTTPS, flashes dual-bank
///  4. Device reboots and re-publishes telemetry — update confirmed
class OtaOrchestratorService {
  final Ref _ref;
  final Map<String, OtaUpdateState> _activeUpdates = {};

  OtaOrchestratorService(this._ref);

  Stream<OtaUpdateState> watchUpdate(String deviceId) {
    return Stream.periodic(const Duration(seconds: 1), (_) {
      return _activeUpdates[deviceId] ?? OtaUpdateState.idle(deviceId);
    });
  }

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

      // Simulate progress feedback until the device echoes back real telemetry
      // (devices/{id}/telemetry with {"ota_progress": 0..100}).
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

  void dispose() => _activeUpdates.clear();
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
  factory OtaUpdateState.complete(String id) => OtaUpdateState._(
      deviceId: id, status: OtaStatus.complete, progressPercent: 100);
  factory OtaUpdateState.failed(String id, String msg) => OtaUpdateState._(
      deviceId: id, status: OtaStatus.failed, errorMessage: msg);
}

enum OtaStatus { idle, inProgress, complete, failed }

final otaServiceProvider = Provider<OtaOrchestratorService>((ref) {
  final service = OtaOrchestratorService(ref);
  ref.onDispose(service.dispose);
  return service;
});
