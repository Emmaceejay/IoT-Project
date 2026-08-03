import 'package:flutter/material.dart';

/// Metadata describing one capability a device can expose.
///
/// Capability definitions are the single source of truth for labels, icons,
/// value ranges, and telemetry/command keys. The UI builder reads these
/// instead of using hardcoded magic values.
class CapabilityDef {
  final String id;
  final String label;
  final IconData icon;
  final bool readOnly;
  final double? min;
  final double? max;
  final double? step;
  final String? unit;

  /// Key used to read this capability's current value from device.telemetry.
  final String telemetryKey;

  /// Key used when sending a command for this capability (empty for read-only).
  final String commandKey;

  const CapabilityDef({
    required this.id,
    required this.label,
    required this.icon,
    this.readOnly = false,
    this.min,
    this.max,
    this.step,
    this.unit,
    required this.telemetryKey,
    required this.commandKey,
  });
}

/// Metadata describing a device product type (e.g. '1-gang switch', 'thermostat').
///
/// Used to look up human-readable names and capability sets by typeId string.
/// The typeId is also stored in [SmartDevice.typeId] so every device knows
/// its own product category without re-deriving it from the capabilities list
/// on every build.
class DeviceTypeDef {
  final String id;
  final String displayName;
  final IconData icon;

  /// Ordered list of capability IDs this type exposes.
  /// Order matters — the UI builder renders capabilities in this sequence.
  final List<String> capabilityIds;

  const DeviceTypeDef({
    required this.id,
    required this.displayName,
    required this.icon,
    required this.capabilityIds,
  });
}
