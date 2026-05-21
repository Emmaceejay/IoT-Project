import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Centralised observability and crash-reporting service.
///
/// Per the architecture whitepaper:
///   "Remote crash logging (via Crashlytics/Sentry)."
///   "Device provisioning success/failure rate tracking."
///   "Centralize connection dropping reports to evaluate hardware fleet health."
///
/// In development: events are written to debugPrint (debug-only output).
/// In production: swap the body of each method to call your chosen SDK:
///   - Firebase Crashlytics: FirebaseCrashlytics.instance.recordError(...)
///   - Sentry:               Sentry.captureException(...)
///   - Datadog / New Relic:  DatadogSdk.instance.logs.error(...)
///
/// Usage:
///   TelemetryService.instance.logMqttDisconnect('broker.host', 'timeout');
class TelemetryService {
  TelemetryService._();
  static final TelemetryService instance = TelemetryService._();

  // ── Generic events ────────────────────────────────────────────────────────

  void logEvent(String name, {Map<String, Object>? properties}) {
    debugPrint('[TELEMETRY] $name ${properties ?? ''}');
    // Production: analytics.logEvent(name: name, parameters: properties);
  }

  void logError(
    Object error,
    StackTrace stack, {
    String? context,
    Map<String, Object>? extra,
  }) {
    debugPrint('[ERROR] ${context ?? ''}: $error\n$stack');
    // Production: Sentry.captureException(error, stackTrace: stack, hint: ...);
    // Production: FirebaseCrashlytics.instance.recordError(error, stack);
  }

  // ── MQTT observability ────────────────────────────────────────────────────

  void logMqttConnected(String brokerHost, bool isLocal) {
    logEvent('mqtt_connected', properties: {
      'broker': brokerHost,
      'is_local': isLocal.toString(),
    });
  }

  void logMqttDisconnect(String brokerHost, String reason) {
    logEvent('mqtt_disconnect', properties: {
      'broker': brokerHost,
      'reason': reason,
    });
  }

  void logMqttFallback(String cloudHost, String localHost) {
    logEvent('mqtt_fallback_to_local', properties: {
      'cloud': cloudHost,
      'local': localHost,
    });
  }

  // ── Provisioning observability ────────────────────────────────────────────

  void logProvisionResult(
    String deviceId, {
    required bool success,
    String? error,
  }) {
    logEvent('device_provisioned', properties: {
      'device_id': deviceId,
      'success': success.toString(),
      if (error != null) 'error': error,
    });
  }

  // ── OTA observability ─────────────────────────────────────────────────────

  void logOtaStarted(String deviceId, String firmwareUrl) {
    logEvent('ota_started', properties: {
      'device_id': deviceId,
      'url': firmwareUrl,
    });
  }

  void logOtaResult(
    String deviceId, {
    required bool success,
    String? error,
  }) {
    logEvent('ota_complete', properties: {
      'device_id': deviceId,
      'success': success.toString(),
      if (error != null) 'error': error,
    });
  }

  // ── Command observability ─────────────────────────────────────────────────

  void logCommandDropped(String deviceId, String reason) {
    logEvent('command_dropped', properties: {
      'device_id': deviceId,
      'reason': reason,
    });
  }
}

/// Riverpod provider exposing the singleton for injection into services.
final telemetryServiceProvider = Provider<TelemetryService>((ref) {
  return TelemetryService.instance;
});
