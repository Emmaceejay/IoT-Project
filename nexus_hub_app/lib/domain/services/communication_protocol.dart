/// Abstract communication protocol interface.
///
/// Per the architecture blueprint: "BLEService, MQTTService, and
/// WifiProvisionService must be independent singletons or injectable services."
/// All transport layers implement this contract so they are swappable and
/// testable without touching domain or UI code.
abstract class CommunicationProtocol {
  /// Establish the connection (broker, BLE peripheral, HTTP reachability).
  Future<void> connect();

  /// Tear down the connection gracefully.
  Future<void> disconnect();

  /// Send a capability command to a specific device.
  /// Returns true if the command was delivered successfully.
  Future<bool> sendCommand(
    String deviceId,
    String capability,
    dynamic value,
  );

  /// True when the protocol has an active, usable connection.
  bool get isConnected;

  /// Human-readable label for logging and UI (e.g. 'MQTT-Cloud', 'HTTP').
  String get protocolName;
}

/// Describes a message received from any transport layer.
class DeviceMessage {
  final String deviceId;

  /// 'status' | 'telemetry' | 'announce' | 'command'
  final String type;

  final Map<String, dynamic> payload;
  final DateTime receivedAt;

  DeviceMessage({
    required this.deviceId,
    required this.type,
    required this.payload,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String toString() =>
      'DeviceMessage(device: $deviceId, type: $type, payload: $payload)';
}
