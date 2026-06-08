import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dsgv_hub_app/domain/models/smart_device.dart';
import 'package:dsgv_hub_app/domain/services/device_manager.dart';
import 'package:dsgv_hub_app/domain/services/mqtt_service.dart';
import 'package:dsgv_hub_app/data/repositories/device_repository.dart';
import 'package:dsgv_hub_app/main.dart';

/// Stub repository — avoids real ObjectBox initialisation in widget tests.
class _StubRepository implements DeviceRepository {
  @override
  Future<List<SmartDevice>> getDevices() async => const [];
  @override
  Future<void> updateDeviceState(String id, Map<String, dynamic> p) async {}
  @override
  Future<void> provisionDevice(SmartDevice device) async {}
  @override
  Future<void> removeDevice(String id) async {}
  @override
  Future<void> renameDevice(String id, String name) async {}
  @override
  Future<void> updateDeviceStatus(String id, DeviceStatus status) async {}
  @override
  Future<void> updatePowerRestoreMode(String id, PowerRestoreMode mode) async {}
}

/// No-op MQTT service — overrides connect() so no socket or timeout timers
/// are created during tests. Inheriting from the real class satisfies Riverpod
/// 2.x's requirement that the factory returns the declared notifier type.
class _StubMqttService extends MqttConnectivityService {
  _StubMqttService(super.ref);

  @override
  Future<void> connect() async {}
}

void main() {
  testWidgets('DSGVHubApp renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Prevent real ObjectBox access.
          deviceRepositoryProvider.overrideWithValue(_StubRepository()),
          // Prevent the 10-second broker connection timeout timer.
          mqttServiceProvider.overrideWith((ref) => _StubMqttService(ref)),
        ],
        child: const DSGVHubApp(),
      ),
    );
    // Settle all async providers and post-frame callbacks.
    await tester.pumpAndSettle();
    expect(find.byType(DSGVHubApp), findsOneWidget);
  });
}
