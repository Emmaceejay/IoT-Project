import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_hub_app/domain/services/ota_service.dart';

void main() {
  group('OtaUpdateState factories', () {
    const id = 'ESP-001';

    test('idle has status idle and 0 progress', () {
      final s = OtaUpdateState.idle(id);
      expect(s.deviceId, id);
      expect(s.status, OtaStatus.idle);
      expect(s.progressPercent, 0);
      expect(s.errorMessage, isNull);
    });

    test('inProgress captures correct progress value', () {
      final s = OtaUpdateState.inProgress(id, 45);
      expect(s.status, OtaStatus.inProgress);
      expect(s.progressPercent, 45);
    });

    test('complete has 100 percent progress', () {
      final s = OtaUpdateState.complete(id);
      expect(s.status, OtaStatus.complete);
      expect(s.progressPercent, 100);
      expect(s.errorMessage, isNull);
    });

    test('failed stores error message', () {
      final s = OtaUpdateState.failed(id, 'timeout');
      expect(s.status, OtaStatus.failed);
      expect(s.errorMessage, 'timeout');
    });

    test('all states carry the correct deviceId', () {
      for (final s in [
        OtaUpdateState.idle(id),
        OtaUpdateState.inProgress(id, 10),
        OtaUpdateState.complete(id),
        OtaUpdateState.failed(id, 'err'),
      ]) {
        expect(s.deviceId, id);
      }
    });
  });
}
