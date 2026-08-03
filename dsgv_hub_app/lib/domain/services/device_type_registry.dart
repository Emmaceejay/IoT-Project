import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/device_type_definition.dart';

/// Central registry for all supported device types and capabilities.
///
/// Adding a new firmware device type is a one-file change: add an entry to
/// [_capabilities] (if the capability is new) and add a [DeviceTypeDef] entry.
/// No changes needed in the UI builder or anywhere else.
///
/// Type inference: when a device announces without an explicit typeId, call
/// [inferTypeId] with its capabilities list to resolve the closest match.
class DeviceTypeRegistry {

  // ── Capability definitions ──────────────────────────────────────────────────
  //
  // Every known capability string has an entry here. The UI builder reads these
  // instead of hardcoding labels, icons, min/max values, or key names.

  static const Map<String, CapabilityDef> _capabilities = {
    'relay': CapabilityDef(
      id: 'relay', label: 'Switch 1',
      icon: Icons.power, telemetryKey: 'power', commandKey: 'power',
    ),
    'relay_2': CapabilityDef(
      id: 'relay_2', label: 'Switch 2',
      icon: Icons.power, telemetryKey: 'power_2', commandKey: 'power_2',
    ),
    'relay_3': CapabilityDef(
      id: 'relay_3', label: 'Switch 3',
      icon: Icons.power, telemetryKey: 'power_3', commandKey: 'power_3',
    ),
    'relay_4': CapabilityDef(
      id: 'relay_4', label: 'Switch 4',
      icon: Icons.power, telemetryKey: 'power_4', commandKey: 'power_4',
    ),
    'brightness': CapabilityDef(
      id: 'brightness', label: 'Brightness',
      icon: Icons.brightness_medium,
      min: 0, max: 100, step: 5, unit: '%',
      telemetryKey: 'brightness', commandKey: 'brightness',
    ),
    'color_temp': CapabilityDef(
      id: 'color_temp', label: 'Color Temp',
      icon: Icons.wb_sunny_outlined,
      min: 2000, max: 6500, step: 100, unit: 'K',
      telemetryKey: 'color_temp', commandKey: 'color_temp',
    ),
    'temperature': CapabilityDef(
      id: 'temperature', label: 'Temperature',
      icon: Icons.thermostat,
      readOnly: true, unit: '°C',
      telemetryKey: 'current_temp', commandKey: '',
    ),
    'humidity': CapabilityDef(
      id: 'humidity', label: 'Humidity',
      icon: Icons.water_drop_outlined,
      readOnly: true, unit: '%',
      telemetryKey: 'humidity', commandKey: '',
    ),
    'motion': CapabilityDef(
      id: 'motion', label: 'Motion',
      icon: Icons.directions_run,
      readOnly: true,
      telemetryKey: 'motion', commandKey: '',
    ),
    'contact': CapabilityDef(
      id: 'contact', label: 'Contact',
      icon: Icons.sensor_door_outlined,
      readOnly: true,
      telemetryKey: 'contact', commandKey: '',
    ),
    'hvac_mode': CapabilityDef(
      id: 'hvac_mode', label: 'HVAC',
      icon: Icons.hvac,
      min: 16, max: 32, step: 0.5, unit: '°C',
      telemetryKey: 'target_temp', commandKey: 'target_temp',
    ),
    'rgb': CapabilityDef(
      id: 'rgb', label: 'RGB Color',
      icon: Icons.palette_outlined,
      min: 0, max: 255, step: 1,
      telemetryKey: 'red', commandKey: 'red',
    ),
  };

  // ── Device type definitions ─────────────────────────────────────────────────

  static const Map<String, DeviceTypeDef> _types = {
    'relay_1g': DeviceTypeDef(
      id: 'relay_1g', displayName: 'Smart Switch (1-gang)',
      icon: Icons.toggle_on_outlined,
      capabilityIds: ['relay'],
    ),
    'relay_2g': DeviceTypeDef(
      id: 'relay_2g', displayName: 'Smart Switch (2-gang)',
      icon: Icons.toggle_on_outlined,
      capabilityIds: ['relay', 'relay_2'],
    ),
    'relay_3g': DeviceTypeDef(
      id: 'relay_3g', displayName: 'Smart Switch (3-gang)',
      icon: Icons.toggle_on_outlined,
      capabilityIds: ['relay', 'relay_2', 'relay_3'],
    ),
    'relay_4g': DeviceTypeDef(
      id: 'relay_4g', displayName: 'Smart Switch (4-gang)',
      icon: Icons.toggle_on_outlined,
      capabilityIds: ['relay', 'relay_2', 'relay_3', 'relay_4'],
    ),
    'dimmer': DeviceTypeDef(
      id: 'dimmer', displayName: 'Smart Dimmer',
      icon: Icons.brightness_medium,
      capabilityIds: ['relay', 'brightness'],
    ),
    'colour_temp': DeviceTypeDef(
      id: 'colour_temp', displayName: 'Color Temperature Light',
      icon: Icons.wb_sunny_outlined,
      capabilityIds: ['relay', 'brightness', 'color_temp'],
    ),
    'rgb_light': DeviceTypeDef(
      id: 'rgb_light', displayName: 'RGB Light',
      icon: Icons.palette_outlined,
      capabilityIds: ['relay', 'rgb'],
    ),
    'temp_sensor': DeviceTypeDef(
      id: 'temp_sensor', displayName: 'Temperature Sensor',
      icon: Icons.thermostat,
      capabilityIds: ['temperature', 'humidity'],
    ),
    'motion_sensor': DeviceTypeDef(
      id: 'motion_sensor', displayName: 'Motion Sensor',
      icon: Icons.motion_photos_on_outlined,
      capabilityIds: ['motion'],
    ),
    'contact_sensor': DeviceTypeDef(
      id: 'contact_sensor', displayName: 'Contact Sensor',
      icon: Icons.sensor_door_outlined,
      capabilityIds: ['contact'],
    ),
    'thermostat': DeviceTypeDef(
      id: 'thermostat', displayName: 'Thermostat',
      icon: Icons.hvac,
      capabilityIds: ['temperature', 'hvac_mode'],
    ),
  };

  // ── Public API ──────────────────────────────────────────────────────────────

  CapabilityDef? lookupCapability(String id) => _capabilities[id];

  DeviceTypeDef? lookupType(String typeId) => _types[typeId];

  Iterable<String> get allTypeIds => _types.keys;

  /// Infer a device type from its capabilities list.
  ///
  /// Used when a device announces without an explicit type_id field —
  /// common with existing firmware that pre-dates the type registry.
  /// Precedence: specific sensors > lighting > relay count.
  String? inferTypeId(List<String> caps) {
    final capSet = caps.toSet();
    if (capSet.contains('hvac_mode'))   return 'thermostat';
    if (capSet.contains('rgb'))          return 'rgb_light';
    if (capSet.contains('color_temp'))   return 'colour_temp';
    if (capSet.contains('brightness'))   return 'dimmer';
    if (capSet.contains('motion'))       return 'motion_sensor';
    if (capSet.contains('contact'))      return 'contact_sensor';
    if (capSet.contains('temperature'))  return 'temp_sensor';

    final relayCount = [
      capSet.contains('relay'),
      capSet.contains('relay_2'),
      capSet.contains('relay_3'),
      capSet.contains('relay_4'),
    ].where((b) => b).length;

    switch (relayCount) {
      case 1: return 'relay_1g';
      case 2: return 'relay_2g';
      case 3: return 'relay_3g';
      case 4: return 'relay_4g';
      default: return null;
    }
  }
}

final deviceTypeRegistryProvider =
    Provider<DeviceTypeRegistry>((_) => DeviceTypeRegistry());
