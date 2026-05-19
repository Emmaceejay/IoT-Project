import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import '../models/mqtt_config.dart';
import 'device_manager.dart';

// ── Connection State ────────────────────────────────────────────────────────

enum HubConnectionState { disconnected, connecting, connected }

// ── Config Notifier (persists to flutter_secure_storage) ───────────────────

class MqttConfigNotifier extends StateNotifier<MqttConfig> {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  MqttConfigNotifier() : super(const MqttConfig()) {
    _load();
  }

  Future<void> _load() async {
    final keys = [
      'mqtt_host', 'mqtt_port', 'mqtt_use_tls',
      'mqtt_username', 'mqtt_password', 'mqtt_client_id',
    ];
    final map = <String, String?>{
      for (final k in keys) k: await _storage.read(key: k),
    };
    state = MqttConfig.fromStorageMap(map);
  }

  Future<void> save(MqttConfig config) async {
    state = config;
    for (final entry in config.toStorageMap().entries) {
      await _storage.write(key: entry.key, value: entry.value);
    }
  }
}

final mqttConfigProvider =
    StateNotifierProvider<MqttConfigNotifier, MqttConfig>((ref) {
  return MqttConfigNotifier();
});

// ── Connectivity Service ────────────────────────────────────────────────────

/// Broker-agnostic MQTT service. Reads config from [mqttConfigProvider].
/// Supports any broker — EMQX, Mosquitto, HiveMQ, AWS IoT Core, etc.
/// TLS and plain connections are both supported based on user config.
class MqttConnectivityService extends StateNotifier<HubConnectionState> {
  final Ref _ref;
  MqttServerClient? _client;
  StreamSubscription? _messageSubscription;

  MqttConnectivityService(this._ref) : super(HubConnectionState.disconnected);

  /// Connect using the currently saved [MqttConfig].
  Future<void> connect() async {
    final config = _ref.read(mqttConfigProvider);
    if (!config.isConfigured) {
      debugPrint('[MQTT] No broker host configured — skipping connect.');
      return;
    }
    await _disconnect();
    state = HubConnectionState.connecting;
    try {
      await _connectWith(config);
    } catch (e) {
      debugPrint('[MQTT] Connection failed: $e');
      state = HubConnectionState.disconnected;
    }
  }

  Future<void> _connectWith(MqttConfig config) async {
    _client = MqttServerClient.withPort(config.host, config.clientId, config.port)
      ..keepAlivePeriod = 60
      ..onDisconnected = _onDisconnected
      ..autoReconnect = true
      ..logging(on: false);

    if (config.useTls) {
      _client!.secure = true;
      _client!.securityContext = SecurityContext.defaultContext;
    }

    final connMsg = MqttConnectMessage()
        .withClientIdentifier(config.clientId)
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();

    if (config.hasCredentials) {
      connMsg.authenticateAs(config.username, config.password);
    }

    _client!.connectionMessage = connMsg;

    await _client!.connect();
    state = HubConnectionState.connected;
    debugPrint(
        '[MQTT] Connected → ${config.host}:${config.port} '
        '| TLS: ${config.useTls} | Auth: ${config.hasCredentials}');
    _subscribeToFleet();
  }

  void _subscribeToFleet() {
    _client!.subscribe('devices/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('devices/+/telemetry', MqttQos.atLeastOnce);

    _messageSubscription?.cancel();
    _messageSubscription =
        _client!.updates!.listen((List<MqttReceivedMessage<MqttMessage>> msgs) {
      for (final msg in msgs) {
        final payload = MqttPublishPayload.bytesToStringAsString(
          (msg.payload as MqttPublishMessage).payload.message,
        );
        _handleIncomingMessage(msg.topic, payload);
      }
    });
  }

  void _handleIncomingMessage(String topic, String payload) {
    final segments = topic.split('/');
    if (segments.length < 3) return;
    final deviceId = segments[1];
    final messageType = segments[2];

    if (messageType == 'status' && payload == 'offline') {
      _ref.read(deviceManagerProvider.notifier).markDeviceOffline(deviceId);
      debugPrint('[MQTT] Device $deviceId went offline (LWT).');
    } else if (messageType == 'telemetry') {
      debugPrint('[MQTT] Telemetry from $deviceId: $payload');
    }
  }

  /// Publish a command to a specific device topic.
  Future<void> publishCommand(String deviceId, String payloadJson) async {
    if (_client == null || state != HubConnectionState.connected) {
      debugPrint('[MQTT] Not connected — command dropped.');
      return;
    }
    final builder = MqttClientPayloadBuilder()..addString(payloadJson);
    _client!.publishMessage(
      'devices/$deviceId/command',
      MqttQos.atLeastOnce,
      builder.payload!,
    );
  }

  void _onDisconnected() {
    state = HubConnectionState.disconnected;
    debugPrint('[MQTT] Disconnected.');
  }

  Future<void> _disconnect() async {
    _messageSubscription?.cancel();
    _messageSubscription = null;
    _client?.disconnect();
    _client = null;
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }
}

final mqttServiceProvider =
    StateNotifierProvider<MqttConnectivityService, HubConnectionState>((ref) {
  return MqttConnectivityService(ref);
});
