import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_hub_app/domain/models/matter_device.dart';

void main() {
  group('MatterDevice', () {
    const baseDevice = MatterDevice(
      uniqueDeviceId: 'TEST-001',
      deviceName: 'Test Bulb',
      status: DeviceStatus.online,
      capabilities: ['relay', 'dimmer'],
      telemetry: {'power': true, 'brightness': 80},
      localIp: '192.168.1.10',
    );

    test('default status is offline', () {
      const d = MatterDevice(uniqueDeviceId: 'X', deviceName: 'X');
      expect(d.status, DeviceStatus.offline);
    });

    test('default capabilities and telemetry are empty', () {
      const d = MatterDevice(uniqueDeviceId: 'X', deviceName: 'X');
      expect(d.capabilities, isEmpty);
      expect(d.telemetry, isEmpty);
    });

    test('copyWith updates only specified fields', () {
      final updated = baseDevice.copyWith(
        deviceName: 'New Name',
        status: DeviceStatus.offline,
      );
      expect(updated.deviceName, 'New Name');
      expect(updated.status, DeviceStatus.offline);
      // unchanged fields preserved
      expect(updated.uniqueDeviceId, 'TEST-001');
      expect(updated.capabilities, ['relay', 'dimmer']);
      expect(updated.localIp, '192.168.1.10');
    });

    test('copyWith with new telemetry does not mutate original', () {
      final updated = baseDevice.copyWith(
        telemetry: {'power': false, 'brightness': 0},
      );
      expect(updated.telemetry['power'], false);
      expect(baseDevice.telemetry['power'], true); // original unchanged
    });

    test('fromJson parses all fields correctly', () {
      final json = {
        'device_id': 'ESP-ABC',
        'name': 'Kitchen Switch',
        'status': 'online',
        'capabilities': ['relay'],
        'telemetry': {'power': false},
        'local_ip': '10.0.0.5',
      };
      final device = MatterDevice.fromJson(json);
      expect(device.uniqueDeviceId, 'ESP-ABC');
      expect(device.deviceName, 'Kitchen Switch');
      expect(device.status, DeviceStatus.online);
      expect(device.capabilities, ['relay']);
      expect(device.telemetry['power'], false);
      expect(device.localIp, '10.0.0.5');
    });

    test('fromJson uses offline status for unknown status string', () {
      final json = {
        'device_id': 'X',
        'name': 'X',
        'status': 'banana',
        'capabilities': <dynamic>[],
        'telemetry': <String, dynamic>{},
      };
      final device = MatterDevice.fromJson(json);
      expect(device.status, DeviceStatus.offline);
    });

    test('fromJson parses provisioning status', () {
      final json = {
        'device_id': 'X',
        'name': 'X',
        'status': 'provisioning',
        'capabilities': <dynamic>[],
        'telemetry': <String, dynamic>{},
      };
      expect(MatterDevice.fromJson(json).status, DeviceStatus.provisioning);
    });

    test('fromJson handles missing optional fields', () {
      final json = {
        'device_id': 'X',
        'name': 'X',
        'capabilities': <dynamic>[],
      };
      final device = MatterDevice.fromJson(json);
      expect(device.localIp, isNull);
      expect(device.telemetry, isEmpty);
      expect(device.status, DeviceStatus.offline);
    });

    test('toJson round-trips all fields', () {
      final json = baseDevice.toJson();
      expect(json['device_id'], 'TEST-001');
      expect(json['name'], 'Test Bulb');
      expect(json['status'], 'online');
      expect(json['capabilities'], ['relay', 'dimmer']);
      expect(json['local_ip'], '192.168.1.10');
    });

    test('toJson omits local_ip when null', () {
      const d = MatterDevice(uniqueDeviceId: 'X', deviceName: 'X');
      expect(d.toJson().containsKey('local_ip'), isFalse);
    });

    test('toJson → fromJson round-trip preserves identity', () {
      final restored = MatterDevice.fromJson(baseDevice.toJson());
      expect(restored.uniqueDeviceId, baseDevice.uniqueDeviceId);
      expect(restored.deviceName, baseDevice.deviceName);
      expect(restored.status, baseDevice.status);
      expect(restored.capabilities, baseDevice.capabilities);
      expect(restored.localIp, baseDevice.localIp);
    });
  });
}
