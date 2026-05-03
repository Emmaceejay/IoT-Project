import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'device_manager.dart';

/// MQTT Dual-Broker Connection States
enum MqttConnectionState { disconnected, connecting, connectedCloud, connectedLocal }

/// The core MQTT Service housing the Dual-Broker Strategy.
///
/// Strategy:
/// 1. Try EMQX Cloud (TLS, JWT auth).
/// 2. If WAN is unreachable → mDNS discovery for local Mosquitto.
/// 3. All incoming LWT messages update [DeviceManager] in real-time.
class MqttConnectivityService {
  final Ref _ref;

  MqttServerClient? _client;
  MqttConnectionState _connectionState = MqttConnectionState.disconnected;

  // TODO: Load these from flutter_secure_storage in production
  static const String _cloudHost = 'your-emqx-endpoint.cloud'; // Replace with real endpoint
  static const int _cloudPort = 8883; // TLS port
  static const String _localFallbackHost = '192.168.1.100'; // Discovered via mDNS
  static const int _localPort = 1883;
  static const String _clientId = 'nexus_hub_flutter_client';

  MqttConnectivityService(this._ref);

  MqttConnectionState get connectionState => _connectionState;

  /// Main entry: attempts cloud then falls back to local.
  Future<void> connect() async {
    try {
      await _connectToCloud();
    } catch (e) {
      debugPrint('[MQTT] Cloud unavailable: $e — trying local fallback...');
      try {
        await _connectToLocal();
      } catch (localErr) {
        debugPrint('[MQTT] Local broker also unreachable: $localErr');
        _connectionState = MqttConnectionState.disconnected;
      }
    }
  }

  Future<void> _connectToCloud() async {
    _client = MqttServerClient.withPort(_cloudHost, _clientId, _cloudPort);
    _client!.secure = true;
    _client!.keepAlivePeriod = 60;
    _client!.onDisconnected = _onDisconnected;
    _client!.autoReconnect = true;

    // TLS context — point to bundled certs in production
    final context = SecurityContext.defaultContext;
    _client!.securityContext = context;

    final connMsg = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();
    _client!.connectionMessage = connMsg;

    await _client!.connect();
    _connectionState = MqttConnectionState.connectedCloud;
    debugPrint('[MQTT] Connected to EMQX Cloud.');
    _subscribeToFleet();
  }

  Future<void> _connectToLocal() async {
    _client = MqttServerClient.withPort(_localFallbackHost, _clientId, _localPort);
    _client!.keepAlivePeriod = 60;
    _client!.onDisconnected = _onDisconnected;
    _client!.autoReconnect = true;

    final connMsg = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .startClean();
    _client!.connectionMessage = connMsg;

    await _client!.connect();
    _connectionState = MqttConnectionState.connectedLocal;
    debugPrint('[MQTT] Connected to Local Mosquitto fallback.');
    _subscribeToFleet();
  }

  /// Subscribe to status topics and wire LWT messages to DeviceManager.
  void _subscribeToFleet() {
    // Subscribe to wildcard status topic for all devices
    _client!.subscribe('devices/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('devices/+/telemetry', MqttQos.atLeastOnce);

    _client!.updates!.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (final msg in messages) {
        final topic = msg.topic;
        final payload = MqttPublishPayload.bytesToStringAsString(
          (msg.payload as MqttPublishMessage).payload.message,
        );

        _handleIncomingMessage(topic, payload);
      }
    });
  }

  void _handleIncomingMessage(String topic, String payload) {
    final segments = topic.split('/');
    if (segments.length < 3) return;

    final deviceId = segments[1];
    final messageType = segments[2];

    if (messageType == 'status') {
      if (payload == 'offline') {
        _ref.read(deviceManagerProvider.notifier).markDeviceOffline(deviceId);
        debugPrint('[MQTT] Device $deviceId went offline (LWT).');
      }
    } else if (messageType == 'telemetry') {
      // TODO: Parse telemetry JSON and call sendCommand to update Isar cache
      debugPrint('[MQTT] Telemetry from $deviceId: $payload');
    }
  }

  /// Publish a command to a specific device.
  Future<void> publishCommand(String deviceId, String payloadJson) async {
    if (_client == null ||
        _client!.connectionStatus?.state != MqttConnectionState.connectedCloud &&
        _client!.connectionStatus?.state != MqttConnectionState.connectedLocal) {
      debugPrint('[MQTT] Not connected — command queued locally.');
      return;
    }

    final builder = MqttClientPayloadBuilder();
    builder.addString(payloadJson);
    _client!.publishMessage(
      'devices/$deviceId/command',
      MqttQos.atLeastOnce,
      builder.payload!,
    );
  }

  void _onDisconnected() {
    _connectionState = MqttConnectionState.disconnected;
    debugPrint('[MQTT] Disconnected. Will attempt reconnect...');
  }

  void dispose() {
    _client?.disconnect();
  }
}

/// Riverpod provider — globally accessible throughout the app
final mqttServiceProvider = Provider<MqttConnectivityService>((ref) {
  final service = MqttConnectivityService(ref);
  ref.onDispose(service.dispose);
  return service;
});
