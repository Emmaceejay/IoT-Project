import '../../domain/models/matter_device.dart';
import '../repositories/device_repository.dart';

/// Mock implementation of [DeviceRepository].
///
/// Seeds realistic fake devices using the same JSON schema that real
/// Matter hardware will broadcast on first connection. Simulates a
/// 400ms network round-trip to make the UI feel real during development.
class MockDeviceDatasource implements DeviceRepository {
  /// In-memory store — will be replaced by Isar in production.
  final List<MatterDevice> _devices = [
    MatterDevice(
      uniqueDeviceId: 'MOCK-ESP32-001',
      deviceName: 'Living Room Bulb',
      status: DeviceStatus.online,
      capabilities: ['relay', 'dimmer', 'color_temperature'],
      telemetry: {'power': true, 'brightness': 75, 'color_temp': 3000},
    ),
    MatterDevice(
      uniqueDeviceId: 'MOCK-ESP32-002',
      deviceName: 'Hall Thermostat',
      status: DeviceStatus.online,
      capabilities: ['temperature_sensor', 'hvac_control'],
      telemetry: {'current_temp': 22.5, 'target_temp': 24.0, 'mode': 'cool'},
    ),
    MatterDevice(
      uniqueDeviceId: 'MOCK-ESP32-003',
      deviceName: 'Garage Door',
      status: DeviceStatus.offline,
      capabilities: ['relay'],
      telemetry: {'power': false},
    ),
  ];

  @override
  Future<List<MatterDevice>> getDevices() async {
    await Future.delayed(const Duration(milliseconds: 400)); // Simulate latency
    return List.unmodifiable(_devices);
  }

  @override
  Future<void> updateDeviceState(String deviceId, Map<String, dynamic> patch) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final index = _devices.indexWhere((d) => d.uniqueDeviceId == deviceId);
    if (index == -1) return;
    final updated = _devices[index].copyWith(
      telemetry: {..._devices[index].telemetry, ...patch},
    );
    _devices[index] = updated;
  }

  @override
  Future<void> provisionDevice(MatterDevice device) async {
    await Future.delayed(const Duration(milliseconds: 300));
    _devices.add(device);
  }

  @override
  Future<void> removeDevice(String deviceId) async {
    _devices.removeWhere((d) => d.uniqueDeviceId == deviceId);
  }
}
