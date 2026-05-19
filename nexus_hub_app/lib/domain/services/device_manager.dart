import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/mock_device_datasource.dart';
import '../../data/repositories/device_repository.dart';
import '../models/matter_device.dart';
import 'local_http_service.dart';
import 'mqtt_service.dart';

/// Riverpod provider wiring in the Mock datasource.
/// Swap [MockDeviceDatasource] for [IsarDeviceDatasource] for production.
final deviceRepositoryProvider = Provider<DeviceRepository>((ref) {
  return MockDeviceDatasource();
});

/// The reactive state engine for all IoT devices.
///
/// Command routing priority:
///   1. Local HTTP (if device has a known IP and phone is on WiFi)
///   2. MQTT (cloud or local broker)
///   3. Repository (in-memory / Isar)
class DeviceManager extends AsyncNotifier<List<MatterDevice>> {
  late DeviceRepository _repository;

  @override
  Future<List<MatterDevice>> build() async {
    _repository = ref.watch(deviceRepositoryProvider);
    return _repository.getDevices();
  }

  /// Refreshes the full device list from the repository.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _repository.getDevices());
  }

  /// Sends a state-change command for [deviceId].
  /// Applies an optimistic UI update first, then dispatches via the best
  /// available transport (local HTTP → MQTT → repository).
  Future<void> sendCommand(String deviceId, Map<String, dynamic> command) async {
    // Optimistic local update — UI reacts instantly
    state = AsyncValue.data(
      state.value!.map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(telemetry: {...d.telemetry, ...command});
      }).toList(),
    );

    // Grab the device reference (has localIp, capabilities, etc.)
    final device = state.value?.firstWhere(
      (d) => d.uniqueDeviceId == deviceId,
      orElse: () => MatterDevice(uniqueDeviceId: deviceId, deviceName: ''),
    );

    // 1. Local HTTP transport — preferred when on same WiFi
    if (device?.localIp != null) {
      final httpService = ref.read(localHttpServiceProvider);
      if (await httpService.isOnWifi()) {
        bool allDelivered = true;
        for (final entry in command.entries) {
          final ok = await httpService.sendCommand(
              device!.localIp!, entry.key, entry.value);
          if (!ok) {
            allDelivered = false;
            break;
          }
        }
        if (allDelivered) return;
        debugPrint('[DeviceManager] HTTP transport failed — falling back to MQTT.');
      }
    }

    // 2. MQTT transport (cloud or local broker)
    final mqttStatus = ref.read(mqttServiceProvider);
    if (mqttStatus.isConnected) {
      final payload = jsonEncode({'device_id': deviceId, ...command});
      await ref.read(mqttServiceProvider.notifier).publishCommand(deviceId, payload);
    }

    // 3. Repository sync (in-memory / Isar)
    await _repository.updateDeviceState(deviceId, command);
  }

  /// Registers a newly commissioned device (called after Matter pairing).
  Future<void> registerNewDevice(MatterDevice device) async {
    await _repository.provisionDevice(device);
    await refresh();
  }

  /// Marks a device as offline — triggered by MQTT LWT messages.
  Future<void> markDeviceOffline(String deviceId) async {
    state = AsyncValue.data(
      state.value!.map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(status: DeviceStatus.offline);
      }).toList(),
    );
  }
}

/// The global provider — all dashboard widgets watch this.
final deviceManagerProvider =
    AsyncNotifierProvider<DeviceManager, List<MatterDevice>>(DeviceManager.new);
