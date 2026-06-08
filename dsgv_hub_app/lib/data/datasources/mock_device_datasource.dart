import '../../domain/models/smart_device.dart';
import '../repositories/device_repository.dart';

/// Mock implementation of [DeviceRepository].
///
/// Seeds realistic fake devices using the same JSON schema that real
/// Matter hardware will broadcast on first connection. Simulates a
/// 400ms network round-trip to make the UI feel real during development.
class MockDeviceDatasource implements DeviceRepository {
  /// In-memory store — replaced by ObjectBox in production.
  final List<SmartDevice> _devices = [
    const SmartDevice(
      uniqueDeviceId: 'MOCK-ESP32-001',
      deviceName: 'Living Room Bulb',
      status: DeviceStatus.online,
      capabilities: ['relay', 'brightness', 'color_temp'],
      telemetry: {'power': true, 'brightness': 75, 'color_temp': 3000},
      localIp: '192.168.1.101', // Simulate device on local LAN
    ),
    const SmartDevice(
      uniqueDeviceId: 'MOCK-ESP32-002',
      deviceName: 'Hall Thermostat',
      status: DeviceStatus.online,
      capabilities: ['temperature', 'hvac_mode'],
      telemetry: {'current_temp': 22.5, 'target_temp': 24.0, 'mode': 'cool'},
      localIp: '192.168.1.102',
    ),
    const SmartDevice(
      uniqueDeviceId: 'MOCK-ESP32-003',
      deviceName: 'Garage Door',
      status: DeviceStatus.offline,
      capabilities: ['relay'],
      telemetry: {'power': false},
      // No localIp — simulates a device not reachable on local network
    ),
  ];

  @override
  Future<List<SmartDevice>> getDevices() async {
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
  Future<void> provisionDevice(SmartDevice device) async {
    await Future.delayed(const Duration(milliseconds: 300));
    _devices.add(device);
  }

  @override
  Future<void> removeDevice(String deviceId) async {
    _devices.removeWhere((d) => d.uniqueDeviceId == deviceId);
  }

  @override
  Future<void> renameDevice(String deviceId, String customName) async {
    final index = _devices.indexWhere((d) => d.uniqueDeviceId == deviceId);
    if (index == -1) return;
    final trimmed = customName.trim().isEmpty ? null : customName.trim();
    _devices[index] = _devices[index].copyWith(customName: trimmed);
  }

  @override
  Future<void> updateDeviceStatus(String deviceId, DeviceStatus status) async {
    final index = _devices.indexWhere((d) => d.uniqueDeviceId == deviceId);
    if (index == -1) return;
    _devices[index] = _devices[index].copyWith(status: status);
  }

  @override
  Future<void> updatePowerRestoreMode(
      String deviceId, PowerRestoreMode mode) async {
    final index = _devices.indexWhere((d) => d.uniqueDeviceId == deviceId);
    if (index == -1) return;
    _devices[index] = _devices[index].copyWith(powerRestoreMode: mode);
  }
}
