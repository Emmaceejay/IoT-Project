import '../../domain/models/device_group.dart';

/// Abstract contract for device group persistence.
///
/// Swap [ObjectBoxGroupDatasource] for a mock in tests without touching any UI.
abstract class DeviceGroupRepository {
  Future<List<DeviceGroup>> getGroups();
  Future<void> saveGroup(DeviceGroup group);
  Future<void> deleteGroup(String groupId);
  Future<void> addDeviceToGroup(String groupId, String deviceId);
  Future<void> removeDeviceFromGroup(String groupId, String deviceId);
}
