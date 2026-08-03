import 'package:objectbox/objectbox.dart';
import '../../domain/models/device_group.dart';
import '../models/device_group_entity.dart';
import '../repositories/device_group_repository.dart';
import '../../objectbox.g.dart';

class ObjectBoxGroupDatasource implements DeviceGroupRepository {
  final Box<DeviceGroupEntity> _box;

  ObjectBoxGroupDatasource(Store store)
      : _box = store.box<DeviceGroupEntity>();

  @override
  Future<List<DeviceGroup>> getGroups() async {
    return _box.getAll().map((e) => e.toDomain()).toList();
  }

  @override
  Future<void> saveGroup(DeviceGroup group) async {
    // Locate any existing entity with this groupId to preserve the ObjectBox int id
    // (required for upsert — without it ObjectBox inserts a duplicate row).
    final existing = _box.getAll().where((e) => e.groupId == group.id).firstOrNull;
    final entity = DeviceGroupEntity.fromDomain(group);
    if (existing != null) entity.id = existing.id;
    _box.put(entity);
  }

  @override
  Future<void> deleteGroup(String groupId) async {
    final toDelete = _box.getAll().where((e) => e.groupId == groupId).map((e) => e.id).toList();
    _box.removeMany(toDelete);
  }

  @override
  Future<void> addDeviceToGroup(String groupId, String deviceId) async {
    final entity = _box.getAll().where((e) => e.groupId == groupId).firstOrNull;
    if (entity == null) return;
    final group = entity.toDomain();
    if (!group.deviceIds.contains(deviceId)) {
      await saveGroup(group.copyWith(deviceIds: [...group.deviceIds, deviceId]));
    }
  }

  @override
  Future<void> removeDeviceFromGroup(String groupId, String deviceId) async {
    final entity = _box.getAll().where((e) => e.groupId == groupId).firstOrNull;
    if (entity == null) return;
    final group = entity.toDomain();
    await saveGroup(group.copyWith(
        deviceIds: group.deviceIds.where((id) => id != deviceId).toList()));
  }
}
