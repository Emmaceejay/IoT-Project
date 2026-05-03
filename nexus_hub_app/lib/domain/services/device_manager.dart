import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/mock_device_datasource.dart';
import '../../data/repositories/device_repository.dart';
import '../models/matter_device.dart';

/// Riverpod provider wiring in the Mock datasource.
/// When ready for production, swap [MockDeviceDatasource] for the
/// [IsarDeviceDatasource] and the entire app will update automatically.
final deviceRepositoryProvider = Provider<DeviceRepository>((ref) {
  return MockDeviceDatasource();
});

/// The reactive state engine for all IoT devices.
///
/// Every widget that "watches" this notifier will automatically
/// redraw whenever a device comes online, updates its telemetry,
/// or gets provisioned / removed.
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

  /// Sends a state change for a specific device (e.g., toggle relay).
  /// Optimistically updates local state immediately, then syncs to the backend.
  Future<void> sendCommand(String deviceId, Map<String, dynamic> command) async {
    // Optimistic local update — the UI reacts instantly
    state = AsyncValue.data(
      state.value!.map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(telemetry: {...d.telemetry, ...command});
      }).toList(),
    );

    // Persist to the repository — in production this will trigger MQTT dispatch
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
