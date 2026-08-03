import 'dart:convert';
import 'package:objectbox/objectbox.dart';
import '../../domain/models/device_group.dart';

@Entity()
class DeviceGroupEntity {
  @Id()
  int id = 0;

  /// Application-level unique ID (UUID string). Separate from ObjectBox's int [id].
  @Unique(onConflict: ConflictStrategy.replace)
  @Index()
  late String groupId;

  late String name;

  /// JSON-encoded List<String> of device MAC addresses in this group.
  late String deviceIdsJson;

  // ── Conversions ─────────────────────────────────────────────────────────────

  DeviceGroup toDomain() => DeviceGroup(
        id: groupId,
        name: name,
        deviceIds: List<String>.from(jsonDecode(deviceIdsJson) as List),
      );

  static DeviceGroupEntity fromDomain(DeviceGroup g) => DeviceGroupEntity()
    ..groupId = g.id
    ..name = g.name
    ..deviceIdsJson = jsonEncode(g.deviceIds);
}
