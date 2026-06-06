import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsgv_hub_app/domain/models/matter_device.dart';
import 'package:dsgv_hub_app/domain/services/device_manager.dart';
import 'package:dsgv_hub_app/data/repositories/device_repository.dart';
import 'package:dsgv_hub_app/presentation/widgets/device_card.dart';

// Minimal stub repository so DeviceManager never touches Isar in tests.
class _StubRepository implements DeviceRepository {
  final List<MatterDevice> devices;
  _StubRepository(this.devices);

  @override
  Future<List<MatterDevice>> getDevices() async => devices;
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

Widget _wrap(Widget child, {List<MatterDevice> devices = const []}) {
  return ProviderScope(
    overrides: [
      deviceRepositoryProvider.overrideWithValue(_StubRepository(devices)),
    ],
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  const onlineDevice = MatterDevice(
    uniqueDeviceId: 'CARD-001',
    deviceName: 'Living Room Bulb',
    status: DeviceStatus.online,
    capabilities: ['relay', 'dimmer'],
    telemetry: {'power': true, 'brightness': 75},
  );

  const offlineDevice = MatterDevice(
    uniqueDeviceId: 'CARD-002',
    deviceName: 'Garage Door',
    status: DeviceStatus.offline,
    capabilities: ['relay'],
    telemetry: {'power': false},
  );

  testWidgets('shows device name', (tester) async {
    await tester.pumpWidget(_wrap(const DeviceCard(device: onlineDevice)));
    expect(find.text('Living Room Bulb'), findsOneWidget);
  });

  testWidgets('online device shows Online label', (tester) async {
    await tester.pumpWidget(_wrap(const DeviceCard(device: onlineDevice)));
    expect(find.text('Online'), findsOneWidget);
  });

  testWidgets('offline device shows Offline label', (tester) async {
    await tester.pumpWidget(_wrap(const DeviceCard(device: offlineDevice)));
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('capability chips appear (up to 2)', (tester) async {
    await tester.pumpWidget(_wrap(const DeviceCard(device: onlineDevice)));
    expect(find.text('relay'), findsOneWidget);
    expect(find.text('dimmer'), findsOneWidget);
  });

  testWidgets('card is collapsed by default — controls not visible', (tester) async {
    await tester.pumpWidget(_wrap(const DeviceCard(device: onlineDevice)));
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('tapping card expands to show controls', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const DeviceCard(device: onlineDevice),
        devices: [onlineDevice],
      ),
    );
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    // relay capability → Switch control
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('tapping again collapses the card', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const DeviceCard(device: onlineDevice),
        devices: [onlineDevice],
      ),
    );
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(find.byType(Switch), findsNothing);
  });
}
