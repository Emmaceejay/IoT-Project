import 'dart:convert';
import 'package:isar/isar.dart';
import '../../domain/models/matter_device.dart';
import '../models/isar_device.dart';
import '../repositories/device_repository.dart';

/// Production [DeviceRepository] backed by the local Isar database.
///
/// Per the architecture whitepaper: "The UI communicates exclusively with a
/// local Isar database cache. Pressing a UI switch instantly mutates Isar,
/// making the app feel zero-latency."
///
/// Receives the [Isar] instance via constructor injection from the Riverpod
/// [isarProvider] — see lib/core/isar_provider.dart.
class IsarDeviceDatasource implements DeviceRepository {
  final Isar _isar;

  const IsarDeviceDatasource(this._isar);

  @override
  Future<List<MatterDevice>> getDevices() async {
    final records = await _isar.isarDevices.where().findAll();
    return records.map((r) => r.toDomain()).toList();
  }

  @override
  Future<void> updateDeviceState(
      String deviceId, Map<String, dynamic> patch) async {
    await _isar.writeTxn(() async {
      final record = await _isar.isarDevices
          .where()
          .uniqueDeviceIdEqualTo(deviceId)
          .findFirst();
      if (record == null) return;

      // Merge patch into existing telemetry
      final existing =
          jsonDecode(record.telemetryJson) as Map<String, dynamic>;
      existing.addAll(patch);
      record.telemetryJson = jsonEncode(existing);
      await _isar.isarDevices.put(record);
    });
  }

  @override
  Future<void> provisionDevice(MatterDevice device) async {
    await _isar.writeTxn(() async {
      // @Index(unique: true, replace: true) handles upsert automatically
      await _isar.isarDevices.put(IsarDevice.fromDomain(device));
    });
  }

  @override
  Future<void> removeDevice(String deviceId) async {
    await _isar.writeTxn(() async {
      await _isar.isarDevices
          .where()
          .uniqueDeviceIdEqualTo(deviceId)
          .deleteFirst();
    });
  }
}
