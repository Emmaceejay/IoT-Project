import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/objectbox_store_provider.dart';
import '../../data/datasources/objectbox_device_datasource.dart';
import '../../data/repositories/device_repository.dart';
import '../models/matter_device.dart';
import 'local_http_service.dart';
import 'mqtt_service.dart';
import 'telemetry_service.dart';

/// Production device repository — ObjectBox-backed, offline-first.
///
/// Architecture whitepaper §4: "The user interface interacts exclusively with
/// a local database cache. Pressing a UI switch instantly mutates the cache,
/// making the app feel zero-latency."
///
/// Swap this provider to [MockDeviceDatasource] for isolated UI development
/// without a running broker or real hardware.
final deviceRepositoryProvider = Provider<DeviceRepository>((ref) {
  final store = ref.watch(objectboxStoreProvider);
  return ObjectBoxDeviceDatasource(store);
});

/// The reactive state engine for all IoT devices.
///
/// Command routing priority (architecture whitepaper §3 — Hybrid Dual-Broker):
///   1. Local HTTP    — if device has [localIp] and phone is on WiFi
///   2. MQTT          — cloud or local broker
///   3. ObjectBox DB  — optimistic update always applied first
class DeviceManager extends AsyncNotifier<List<MatterDevice>> {
  late DeviceRepository _repository;

  @override
  Future<List<MatterDevice>> build() async {
    _repository = ref.watch(deviceRepositoryProvider);
    return _repository.getDevices();
  }

  /// Refreshes the full device list from the Isar cache.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _repository.getDevices());
  }

  /// Sends a state-change command for [deviceId].
  ///
  /// 1. Optimistic UI update (instant, zero-latency)
  /// 2. Local HTTP transport (if on same WiFi and device has IP)
  /// 3. MQTT (cloud or local broker fallback)
  /// 4. Isar persistence
  Future<void> sendCommand(String deviceId, Map<String, dynamic> command) async {
    // Optimistic update — UI reacts instantly before any network round-trip
    state = AsyncValue.data(
      (state.valueOrNull ?? []).map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(telemetry: {...d.telemetry, ...command});
      }).toList(),
    );

    final device = state.value?.firstWhere(
      (d) => d.uniqueDeviceId == deviceId,
      orElse: () => MatterDevice(uniqueDeviceId: deviceId, deviceName: ''),
    );

    // 1. Local HTTP — preferred transport when on same LAN
    final localIp = device?.localIp;
    if (localIp != null && localIp.isNotEmpty) {
      final httpService = ref.read(localHttpServiceProvider);
      if (await httpService.isOnWifi()) {
        bool allDelivered = true;
        for (final entry in command.entries) {
          final ok = await httpService.sendCommand(
              localIp, entry.key, entry.value);
          if (!ok) {
            allDelivered = false;
            break;
          }
        }
        if (allDelivered) {
          await _repository.updateDeviceState(deviceId, command);
          return;
        }
        debugPrint('[DeviceManager] HTTP failed — falling back to MQTT.');
        ref.read(telemetryServiceProvider).logCommandDropped(
            deviceId, 'local_http_failed');
      }
    }

    // 2. MQTT transport
    final mqttStatus = ref.read(mqttServiceProvider);
    if (mqttStatus.isConnected) {
      final payload = jsonEncode({'device_id': deviceId, ...command});
      await ref.read(mqttServiceProvider.notifier).publishCommand(deviceId, payload);
    } else {
      ref.read(telemetryServiceProvider).logCommandDropped(
          deviceId, 'no_transport_available');
    }

    // 3. Persist to ObjectBox cache
    await _repository.updateDeviceState(deviceId, command);
  }

  /// Registers a newly commissioned device (called after Matter pairing).
  Future<void> registerNewDevice(MatterDevice device) async {
    await _repository.provisionDevice(device);
    ref.read(telemetryServiceProvider).logProvisionResult(
        device.uniqueDeviceId, success: true);
    await refresh();
  }

  /// Marks a device as offline — triggered by MQTT LWT messages.
  Future<void> markDeviceOffline(String deviceId) async {
    state = AsyncValue.data(
      (state.valueOrNull ?? []).map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(status: DeviceStatus.offline);
      }).toList(),
    );
    await _repository.updateDeviceState(deviceId, {'_status': 'offline'});
  }

  /// Applies live telemetry payload from MQTT to the matching device.
  void applyTelemetry(String deviceId, Map<String, dynamic> telemetry) {
    final devices = state.value;
    if (devices == null) return;
    state = AsyncValue.data(
      devices.map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(
          status: DeviceStatus.online,
          telemetry: {...d.telemetry, ...telemetry},
        );
      }).toList(),
    );
    _repository.updateDeviceState(deviceId, telemetry);
  }

  /// Handles a device announce message from MQTT.
  /// Registers unknown devices or updates [localIp] for known ones.
  Future<void> handleAnnounce(MatterDevice announced) async {
    final devices = state.value ?? [];
    final existingIndex = devices.indexWhere(
        (d) => d.uniqueDeviceId == announced.uniqueDeviceId);

    if (existingIndex == -1) {
      await _repository.provisionDevice(announced);
      state = AsyncValue.data([...devices, announced]);
    } else {
      state = AsyncValue.data(
        devices.map((d) {
          if (d.uniqueDeviceId != announced.uniqueDeviceId) return d;
          return d.copyWith(
            status: DeviceStatus.online,
            localIp: announced.localIp ?? d.localIp,
            capabilities: announced.capabilities.isNotEmpty
                ? announced.capabilities
                : d.capabilities,
          );
        }).toList(),
      );
      await _repository.provisionDevice(
        announced.copyWith(localIp: announced.localIp),
      );
    }
  }
}

/// The global provider — all dashboard widgets watch this.
final deviceManagerProvider =
    AsyncNotifierProvider<DeviceManager, List<MatterDevice>>(DeviceManager.new);
