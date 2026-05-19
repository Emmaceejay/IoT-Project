// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'isar_device.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetIsarDeviceCollection on Isar {
  IsarCollection<IsarDevice> get isarDevices => this.collection();
}

const IsarDeviceSchema = CollectionSchema(
  name: r'IsarDevice',
  id: -7214496233782767287,
  properties: {
    r'capabilities': PropertySchema(
      id: 0,
      name: r'capabilities',
      type: IsarType.stringList,
    ),
    r'deviceName': PropertySchema(
      id: 1,
      name: r'deviceName',
      type: IsarType.string,
    ),
    r'localIp': PropertySchema(
      id: 2,
      name: r'localIp',
      type: IsarType.string,
    ),
    r'status': PropertySchema(
      id: 3,
      name: r'status',
      type: IsarType.string,
      enumMap: _IsarDevicestatusEnumValueMap,
    ),
    r'telemetryJson': PropertySchema(
      id: 4,
      name: r'telemetryJson',
      type: IsarType.string,
    ),
    r'uniqueDeviceId': PropertySchema(
      id: 5,
      name: r'uniqueDeviceId',
      type: IsarType.string,
    )
  },
  estimateSize: _isarDeviceEstimateSize,
  serialize: _isarDeviceSerialize,
  deserialize: _isarDeviceDeserialize,
  deserializeProp: _isarDeviceDeserializeProp,
  idName: r'id',
  indexes: {
    r'uniqueDeviceId': IndexSchema(
      id: -2321538480737604909,
      name: r'uniqueDeviceId',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'uniqueDeviceId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _isarDeviceGetId,
  getLinks: _isarDeviceGetLinks,
  attach: _isarDeviceAttach,
  version: '3.1.0+1',
);

int _isarDeviceEstimateSize(
  IsarDevice object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.capabilities.length * 3;
  {
    for (var i = 0; i < object.capabilities.length; i++) {
      final value = object.capabilities[i];
      bytesCount += value.length * 3;
    }
  }
  bytesCount += 3 + object.deviceName.length * 3;
  {
    final value = object.localIp;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.status.name.length * 3;
  bytesCount += 3 + object.telemetryJson.length * 3;
  bytesCount += 3 + object.uniqueDeviceId.length * 3;
  return bytesCount;
}

void _isarDeviceSerialize(
  IsarDevice object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeStringList(offsets[0], object.capabilities);
  writer.writeString(offsets[1], object.deviceName);
  writer.writeString(offsets[2], object.localIp);
  writer.writeString(offsets[3], object.status.name);
  writer.writeString(offsets[4], object.telemetryJson);
  writer.writeString(offsets[5], object.uniqueDeviceId);
}

IsarDevice _isarDeviceDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = IsarDevice();
  object.capabilities = reader.readStringList(offsets[0]) ?? [];
  object.deviceName = reader.readString(offsets[1]);
  object.id = id;
  object.localIp = reader.readStringOrNull(offsets[2]);
  object.status =
      _IsarDevicestatusValueEnumMap[reader.readStringOrNull(offsets[3])] ??
          DeviceStatus.online;
  object.telemetryJson = reader.readString(offsets[4]);
  object.uniqueDeviceId = reader.readString(offsets[5]);
  return object;
}

P _isarDeviceDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readStringList(offset) ?? []) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readStringOrNull(offset)) as P;
    case 3:
      return (_IsarDevicestatusValueEnumMap[reader.readStringOrNull(offset)] ??
          DeviceStatus.online) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

const _IsarDevicestatusEnumValueMap = {
  r'online': r'online',
  r'offline': r'offline',
  r'provisioning': r'provisioning',
};
const _IsarDevicestatusValueEnumMap = {
  r'online': DeviceStatus.online,
  r'offline': DeviceStatus.offline,
  r'provisioning': DeviceStatus.provisioning,
};

Id _isarDeviceGetId(IsarDevice object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _isarDeviceGetLinks(IsarDevice object) {
  return [];
}

void _isarDeviceAttach(IsarCollection<dynamic> col, Id id, IsarDevice object) {
  object.id = id;
}

extension IsarDeviceByIndex on IsarCollection<IsarDevice> {
  Future<IsarDevice?> getByUniqueDeviceId(String uniqueDeviceId) {
    return getByIndex(r'uniqueDeviceId', [uniqueDeviceId]);
  }

  IsarDevice? getByUniqueDeviceIdSync(String uniqueDeviceId) {
    return getByIndexSync(r'uniqueDeviceId', [uniqueDeviceId]);
  }

  Future<bool> deleteByUniqueDeviceId(String uniqueDeviceId) {
    return deleteByIndex(r'uniqueDeviceId', [uniqueDeviceId]);
  }

  bool deleteByUniqueDeviceIdSync(String uniqueDeviceId) {
    return deleteByIndexSync(r'uniqueDeviceId', [uniqueDeviceId]);
  }

  Future<List<IsarDevice?>> getAllByUniqueDeviceId(
      List<String> uniqueDeviceIdValues) {
    final values = uniqueDeviceIdValues.map((e) => [e]).toList();
    return getAllByIndex(r'uniqueDeviceId', values);
  }

  List<IsarDevice?> getAllByUniqueDeviceIdSync(
      List<String> uniqueDeviceIdValues) {
    final values = uniqueDeviceIdValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'uniqueDeviceId', values);
  }

  Future<int> deleteAllByUniqueDeviceId(List<String> uniqueDeviceIdValues) {
    final values = uniqueDeviceIdValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'uniqueDeviceId', values);
  }

  int deleteAllByUniqueDeviceIdSync(List<String> uniqueDeviceIdValues) {
    final values = uniqueDeviceIdValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'uniqueDeviceId', values);
  }

  Future<Id> putByUniqueDeviceId(IsarDevice object) {
    return putByIndex(r'uniqueDeviceId', object);
  }

  Id putByUniqueDeviceIdSync(IsarDevice object, {bool saveLinks = true}) {
    return putByIndexSync(r'uniqueDeviceId', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByUniqueDeviceId(List<IsarDevice> objects) {
    return putAllByIndex(r'uniqueDeviceId', objects);
  }

  List<Id> putAllByUniqueDeviceIdSync(List<IsarDevice> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'uniqueDeviceId', objects, saveLinks: saveLinks);
  }
}

extension IsarDeviceQueryWhereSort
    on QueryBuilder<IsarDevice, IsarDevice, QWhere> {
  QueryBuilder<IsarDevice, IsarDevice, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension IsarDeviceQueryWhere
    on QueryBuilder<IsarDevice, IsarDevice, QWhereClause> {
  QueryBuilder<IsarDevice, IsarDevice, QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterWhereClause> idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterWhereClause> idGreaterThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterWhereClause> idLessThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterWhereClause> uniqueDeviceIdEqualTo(
      String uniqueDeviceId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'uniqueDeviceId',
        value: [uniqueDeviceId],
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterWhereClause>
      uniqueDeviceIdNotEqualTo(String uniqueDeviceId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'uniqueDeviceId',
              lower: [],
              upper: [uniqueDeviceId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'uniqueDeviceId',
              lower: [uniqueDeviceId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'uniqueDeviceId',
              lower: [uniqueDeviceId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'uniqueDeviceId',
              lower: [],
              upper: [uniqueDeviceId],
              includeUpper: false,
            ));
      }
    });
  }
}

extension IsarDeviceQueryFilter
    on QueryBuilder<IsarDevice, IsarDevice, QFilterCondition> {
  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'capabilities',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'capabilities',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'capabilities',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'capabilities',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'capabilities',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'capabilities',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'capabilities',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'capabilities',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'capabilities',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesElementIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'capabilities',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'capabilities',
        length,
        true,
        length,
        true,
      );
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'capabilities',
        0,
        true,
        0,
        true,
      );
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'capabilities',
        0,
        false,
        999999,
        true,
      );
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesLengthLessThan(
    int length, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'capabilities',
        0,
        true,
        length,
        include,
      );
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesLengthGreaterThan(
    int length, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'capabilities',
        length,
        include,
        999999,
        true,
      );
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      capabilitiesLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'capabilities',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> deviceNameEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'deviceName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      deviceNameGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'deviceName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      deviceNameLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'deviceName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> deviceNameBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'deviceName',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      deviceNameStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'deviceName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      deviceNameEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'deviceName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      deviceNameContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'deviceName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> deviceNameMatches(
      String pattern,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'deviceName',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      deviceNameIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'deviceName',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      deviceNameIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'deviceName',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> idEqualTo(
      Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'localIp',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      localIpIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'localIp',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'localIp',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      localIpGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'localIp',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'localIp',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'localIp',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'localIp',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'localIp',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpContains(
      String value,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'localIp',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpMatches(
      String pattern,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'localIp',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> localIpIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'localIp',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      localIpIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'localIp',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusEqualTo(
    DeviceStatus value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusGreaterThan(
    DeviceStatus value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusLessThan(
    DeviceStatus value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusBetween(
    DeviceStatus lower,
    DeviceStatus upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'status',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusContains(
      String value,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusMatches(
      String pattern,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'status',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition> statusIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'status',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      statusIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'status',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'telemetryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'telemetryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'telemetryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'telemetryJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'telemetryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'telemetryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'telemetryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'telemetryJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'telemetryJson',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      telemetryJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'telemetryJson',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'uniqueDeviceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'uniqueDeviceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'uniqueDeviceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'uniqueDeviceId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'uniqueDeviceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'uniqueDeviceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'uniqueDeviceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'uniqueDeviceId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'uniqueDeviceId',
        value: '',
      ));
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterFilterCondition>
      uniqueDeviceIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'uniqueDeviceId',
        value: '',
      ));
    });
  }
}

extension IsarDeviceQueryObject
    on QueryBuilder<IsarDevice, IsarDevice, QFilterCondition> {}

extension IsarDeviceQueryLinks
    on QueryBuilder<IsarDevice, IsarDevice, QFilterCondition> {}

extension IsarDeviceQuerySortBy
    on QueryBuilder<IsarDevice, IsarDevice, QSortBy> {
  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByDeviceName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'deviceName', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByDeviceNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'deviceName', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByLocalIp() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'localIp', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByLocalIpDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'localIp', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByStatus() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByStatusDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByTelemetryJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'telemetryJson', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByTelemetryJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'telemetryJson', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> sortByUniqueDeviceId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uniqueDeviceId', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy>
      sortByUniqueDeviceIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uniqueDeviceId', Sort.desc);
    });
  }
}

extension IsarDeviceQuerySortThenBy
    on QueryBuilder<IsarDevice, IsarDevice, QSortThenBy> {
  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByDeviceName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'deviceName', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByDeviceNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'deviceName', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByLocalIp() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'localIp', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByLocalIpDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'localIp', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByStatus() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByStatusDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByTelemetryJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'telemetryJson', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByTelemetryJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'telemetryJson', Sort.desc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy> thenByUniqueDeviceId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uniqueDeviceId', Sort.asc);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QAfterSortBy>
      thenByUniqueDeviceIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uniqueDeviceId', Sort.desc);
    });
  }
}

extension IsarDeviceQueryWhereDistinct
    on QueryBuilder<IsarDevice, IsarDevice, QDistinct> {
  QueryBuilder<IsarDevice, IsarDevice, QDistinct> distinctByCapabilities() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'capabilities');
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QDistinct> distinctByDeviceName(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'deviceName', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QDistinct> distinctByLocalIp(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'localIp', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QDistinct> distinctByStatus(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'status', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QDistinct> distinctByTelemetryJson(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'telemetryJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IsarDevice, IsarDevice, QDistinct> distinctByUniqueDeviceId(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'uniqueDeviceId',
          caseSensitive: caseSensitive);
    });
  }
}

extension IsarDeviceQueryProperty
    on QueryBuilder<IsarDevice, IsarDevice, QQueryProperty> {
  QueryBuilder<IsarDevice, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<IsarDevice, List<String>, QQueryOperations>
      capabilitiesProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'capabilities');
    });
  }

  QueryBuilder<IsarDevice, String, QQueryOperations> deviceNameProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'deviceName');
    });
  }

  QueryBuilder<IsarDevice, String?, QQueryOperations> localIpProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'localIp');
    });
  }

  QueryBuilder<IsarDevice, DeviceStatus, QQueryOperations> statusProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'status');
    });
  }

  QueryBuilder<IsarDevice, String, QQueryOperations> telemetryJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'telemetryJson');
    });
  }

  QueryBuilder<IsarDevice, String, QQueryOperations> uniqueDeviceIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'uniqueDeviceId');
    });
  }
}
