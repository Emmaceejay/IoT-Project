import '../../domain/models/matter_device.dart';

/// Abstract contract for all device data sources.
///
/// By hiding implementation behind this interface,
/// we can swap the Mock datasource → Isar local cache → real MQTT
/// without touching a single widget or Riverpod provider.
abstract class DeviceRepository {
  /// Returns the current list of all known devices.
  Future<List<MatterDevice>> getDevices();

  /// Updates a device's status or telemetry in the local cache.
  Future<void> updateDeviceState(String deviceId, Map<String, dynamic> patch);

  /// Registers a newly commissioned Matter device into the local registry.
  Future<void> provisionDevice(MatterDevice device);

  /// Removes a device from the local registry.
  Future<void> removeDevice(String deviceId);
}
