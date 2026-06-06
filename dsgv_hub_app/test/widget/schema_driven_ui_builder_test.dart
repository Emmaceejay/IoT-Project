import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsgv_hub_app/domain/models/matter_device.dart';
import 'package:dsgv_hub_app/domain/services/device_manager.dart';
import 'package:dsgv_hub_app/data/repositories/device_repository.dart';
import 'package:dsgv_hub_app/presentation/widgets/schema_driven_ui_builder.dart';

class _StubRepository implements DeviceRepository {
  @override
  Future<List<MatterDevice>> getDevices() async => [];
  @override
  Future<void> updateDeviceState(String id, Map<String, dynamic> patch) async {}
  @override
  Future<void> provisionDevice(MatterDevice device) async {}
  @override
  Future<void> removeDevice(String id) async {}
  @override
  Future<void> renameDevice(String id, String name) async {}
  @override
  Future<void> updateDeviceStatus(String id, DeviceStatus status) async {}
}

Widget _wrap(MatterDevice device) {
  return ProviderScope(
    overrides: [
      deviceRepositoryProvider.overrideWithValue(_StubRepository()),
    ],
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(
        body: SchemaDrivenUiBuilder(device: device),
      ),
    ),
  );
}

void main() {
  group('SchemaDrivenUiBuilder', () {
    testWidgets('relay capability renders a Switch', (tester) async {
      const device = MatterDevice(
        uniqueDeviceId: 'S-001',
        deviceName: 'Switch',
        status: DeviceStatus.online,
        capabilities: ['relay'],
        telemetry: {'power': false},
      );
      await tester.pumpWidget(_wrap(device));
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('Switch 1'), findsOneWidget);
    });

    testWidgets('brightness capability renders a Slider', (tester) async {
      const device = MatterDevice(
        uniqueDeviceId: 'S-002',
        deviceName: 'Dimmer',
        status: DeviceStatus.online,
        capabilities: ['brightness'],
        telemetry: {'brightness': 50},
      );
      await tester.pumpWidget(_wrap(device));
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('temperature capability shows read-only value', (tester) async {
      const device = MatterDevice(
        uniqueDeviceId: 'S-003',
        deviceName: 'Sensor',
        status: DeviceStatus.online,
        capabilities: ['temperature'],
        telemetry: {'current_temp': 23.5},
      );
      await tester.pumpWidget(_wrap(device));
      expect(find.text('23.5 °C'), findsOneWidget);
    });

    testWidgets('unknown capability shows fallback text', (tester) async {
      const device = MatterDevice(
        uniqueDeviceId: 'S-004',
        deviceName: 'Unknown',
        status: DeviceStatus.online,
        capabilities: ['laser_cannon'],
        telemetry: {},
      );
      await tester.pumpWidget(_wrap(device));
      expect(find.text('Unsupported capability'), findsOneWidget);
    });

    testWidgets('offline device absorbs pointer input', (tester) async {
      const device = MatterDevice(
        uniqueDeviceId: 'S-005',
        deviceName: 'Offline',
        status: DeviceStatus.offline,
        capabilities: ['relay'],
        telemetry: {'power': false},
      );
      await tester.pumpWidget(_wrap(device));
      // Find the AbsorbPointer that is a direct child of SchemaDrivenUiBuilder.
      final absorb = tester.widget<AbsorbPointer>(
        find.descendant(
          of: find.byType(SchemaDrivenUiBuilder),
          matching: find.byType(AbsorbPointer),
        ).first,
      );
      expect(absorb.absorbing, true);
    });

    testWidgets('online device does not absorb pointer input', (tester) async {
      const device = MatterDevice(
        uniqueDeviceId: 'S-006',
        deviceName: 'Online',
        status: DeviceStatus.online,
        capabilities: ['relay'],
        telemetry: {'power': true},
      );
      await tester.pumpWidget(_wrap(device));
      final absorb = tester.widget<AbsorbPointer>(
        find.descendant(
          of: find.byType(SchemaDrivenUiBuilder),
          matching: find.byType(AbsorbPointer),
        ).first,
      );
      expect(absorb.absorbing, false);
    });

    testWidgets('multiple capabilities each render their control', (tester) async {
      const device = MatterDevice(
        uniqueDeviceId: 'S-007',
        deviceName: 'Multi',
        status: DeviceStatus.online,
        capabilities: ['relay', 'brightness', 'color_temp'],
        telemetry: {'power': true, 'brightness': 70, 'color_temp': 4000},
      );
      await tester.pumpWidget(_wrap(device));
      expect(find.byType(Switch), findsOneWidget);
      // Two sliders: brightness + color_temp
      expect(find.byType(Slider), findsNWidgets(2));
    });
  });
}
