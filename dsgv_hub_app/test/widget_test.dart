import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dsgv_hub_app/domain/models/matter_device.dart';
import 'package:dsgv_hub_app/domain/services/device_manager.dart';
import 'package:dsgv_hub_app/data/repositories/device_repository.dart';
import 'package:dsgv_hub_app/main.dart';

/// Stub repository — avoids real Isar initialisation in widget tests.
class _StubRepository implements DeviceRepository {
  @override
  Future<List<MatterDevice>> getDevices() async => const [];
  @override
  Future<void> updateDeviceState(String id, Map<String, dynamic> p) async {}
  @override
  Future<void> provisionDevice(MatterDevice device) async {}
  @override
  Future<void> removeDevice(String id) async {}
}

void main() {
  testWidgets('DSGVHubApp renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Override the repository so DeviceManager never calls Isar.
          deviceRepositoryProvider.overrideWithValue(_StubRepository()),
        ],
        child: const DSGVHubApp(),
      ),
    );
    // Let async providers (device load) settle.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(DSGVHubApp), findsOneWidget);
  });
}
