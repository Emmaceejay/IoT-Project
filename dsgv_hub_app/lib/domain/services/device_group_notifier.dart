import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/objectbox_store_provider.dart';
import '../../data/datasources/objectbox_group_datasource.dart';
import '../../data/repositories/device_group_repository.dart';
import '../models/device_group.dart';
import 'device_manager.dart';

final deviceGroupRepositoryProvider = Provider<DeviceGroupRepository>((ref) {
  final store = ref.watch(objectboxStoreProvider);
  return ObjectBoxGroupDatasource(store);
});

/// Manages the list of device groups and exposes batch-command operations.
class DeviceGroupNotifier extends AsyncNotifier<List<DeviceGroup>> {
  late DeviceGroupRepository _repo;

  @override
  Future<List<DeviceGroup>> build() async {
    _repo = ref.watch(deviceGroupRepositoryProvider);
    return _repo.getGroups();
  }

  Future<void> createGroup(String name) async {
    final id = '${DateTime.now().millisecondsSinceEpoch}_${name.trim().hashCode.abs()}';
    final group = DeviceGroup(id: id, name: name.trim());
    await _repo.saveGroup(group);
    state = AsyncValue.data([...state.valueOrNull ?? [], group]);
    debugPrint('[Groups] Created group "${group.name}" (${group.id})');
  }

  Future<void> deleteGroup(String groupId) async {
    await _repo.deleteGroup(groupId);
    state = AsyncValue.data(
        (state.valueOrNull ?? []).where((g) => g.id != groupId).toList());
    debugPrint('[Groups] Deleted group $groupId');
  }

  Future<void> addDevice(String groupId, String deviceId) async {
    await _repo.addDeviceToGroup(groupId, deviceId);
    _refresh();
  }

  Future<void> removeDevice(String groupId, String deviceId) async {
    await _repo.removeDeviceFromGroup(groupId, deviceId);
    _refresh();
  }

  /// Sends [command] to every device in the group via [DeviceManager.sendCommand].
  Future<void> sendCommandToGroup(
      String groupId, Map<String, dynamic> command) async {
    final group = (state.valueOrNull ?? [])
        .where((g) => g.id == groupId)
        .firstOrNull;
    if (group == null) return;

    final manager = ref.read(deviceManagerProvider.notifier);
    await Future.wait(
        group.deviceIds.map((id) => manager.sendCommand(id, command)));
    debugPrint('[Groups] Sent $command to ${group.deviceIds.length} device(s) in "${group.name}"');
  }

  Future<void> _refresh() async {
    final groups = await _repo.getGroups();
    state = AsyncValue.data(groups);
  }
}

final deviceGroupProvider =
    AsyncNotifierProvider<DeviceGroupNotifier, List<DeviceGroup>>(
        DeviceGroupNotifier.new);
