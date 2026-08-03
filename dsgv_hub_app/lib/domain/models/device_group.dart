/// A named collection of devices (e.g. "Living Room", "Outdoor Lights").
///
/// Groups enable batch commands — toggle all devices in a room at once.
/// Groups are stored locally in ObjectBox and are never synced to the broker.
class DeviceGroup {
  final String id;
  final String name;
  final List<String> deviceIds;

  const DeviceGroup({
    required this.id,
    required this.name,
    this.deviceIds = const [],
  });

  DeviceGroup copyWith({
    String? name,
    List<String>? deviceIds,
  }) {
    return DeviceGroup(
      id: id,
      name: name ?? this.name,
      deviceIds: deviceIds ?? this.deviceIds,
    );
  }

  @override
  String toString() => 'DeviceGroup($id, "$name", ${deviceIds.length} devices)';
}
