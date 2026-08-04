import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/objectbox_store_provider.dart';
import '../../data/datasources/objectbox_group_datasource.dart';
import '../../data/repositories/device_group_repository.dart';
import '../models/device_group.dart';
import '../models/smart_device.dart';
import 'device_manager.dart';
import 'device_type_registry.dart';

/// Relay capability IDs in gang order — matches device_type_registry.dart.
const _relayCapabilityIds = ['relay', 'relay_2', 'relay_3', 'relay_4'];

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
  ///
  /// A bare `{'power': value}` — what the group's all-on/all-off buttons send —
  /// is expanded per device to every relay capability it actually has
  /// (power, power_2, power_3, power_4), so a multi-gang switch's extra gangs
  /// aren't silently left in their previous state. Devices with no relay
  /// capability at all (sensors) are skipped rather than sent a no-op 'power'
  /// command. Any other command shape passes through unchanged.
  Future<void> sendCommandToGroup(
      String groupId, Map<String, dynamic> command) async {
    final group = (state.valueOrNull ?? [])
        .where((g) => g.id == groupId)
        .firstOrNull;
    if (group == null) return;

    final manager = ref.read(deviceManagerProvider.notifier);
    final devices = ref.read(deviceManagerProvider).valueOrNull ?? [];
    final registry = ref.read(deviceTypeRegistryProvider);

    final targets = group.deviceIds
        .map((id) => devices.where((d) => d.uniqueDeviceId == id).firstOrNull)
        .whereType<SmartDevice>();

    var sentCount = 0;
    await Future.wait(targets.map((device) {
      final resolved = _resolveCommand(device, command, registry);
      if (resolved.isEmpty) return Future<void>.value();
      sentCount++;
      return manager.sendCommand(device.uniqueDeviceId, resolved);
    }));
    debugPrint('[Groups] Sent $command to $sentCount device(s) in "${group.name}"');
  }

  Map<String, dynamic> _resolveCommand(
    SmartDevice device,
    Map<String, dynamic> command,
    DeviceTypeRegistry registry,
  ) {
    if (command.length != 1 || !command.containsKey('power')) {
      return command;
    }

    final value = command['power'];
    final expanded = <String, dynamic>{};
    for (final capId in _relayCapabilityIds) {
      if (device.capabilities.contains(capId)) {
        expanded[registry.lookupCapability(capId)!.commandKey] = value;
      }
    }
    return expanded;
  }

  Future<void> _refresh() async {
    final groups = await _repo.getGroups();
    state = AsyncValue.data(groups);
  }
}

final deviceGroupProvider =
    AsyncNotifierProvider<DeviceGroupNotifier, List<DeviceGroup>>(
        DeviceGroupNotifier.new);
