import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import '../models/matter_device.dart';
import '../models/mqtt_config.dart';
import 'device_manager.dart';

// ── Connection State ────────────────────────────────────────────────────────

enum HubConnectionState {
  disconnected,
  connecting,
  connectedCloud,  // any remote / public broker
  connectedLocal,  // private-IP broker (192.168.x, 10.x, etc.)
  connectedDirect, // direct HTTP transport (Matter / Tasmota)
}

class MqttConnectionStatus {
  final HubConnectionState state;
  final String? errorMessage;

  const MqttConnectionStatus(this.state, [this.errorMessage]);

  bool get isConnected =>
      state == HubConnectionState.connectedCloud ||
      state == HubConnectionState.connectedLocal ||
      state == HubConnectionState.connectedDirect;
}

// ── Factory Mode Notifier ───────────────────────────────────────────────────
// Controls whether the app uses the manufacturer's pre-configured broker
// or a user-supplied custom broker. Defaults to factory (true) on fresh install.

class MqttFactoryModeNotifier extends StateNotifier<bool> {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _key = 'mqtt_use_factory';

  MqttFactoryModeNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final val = await _storage.read(key: _key);
    // Treat null (first install) and 'true' as factory mode
    state = val != 'false';
  }

  Future<void> setFactoryMode(bool useFactory) async {
    state = useFactory;
    await _storage.write(key: _key, value: useFactory.toString());
  }
}

final mqttUseFactoryProvider =
    StateNotifierProvider<MqttFactoryModeNotifier, bool>((ref) {
  return MqttFactoryModeNotifier();
});

// ── Config Notifier (persists user's custom broker via flutter_secure_storage)

class MqttConfigNotifier extends StateNotifier<MqttConfig> {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  MqttConfigNotifier() : super(const MqttConfig()) {
    _load();
  }

  Future<void> _load() async {
    const keys = [
      'mqtt_host', 'mqtt_port', 'mqtt_use_tls',
      'mqtt_username', 'mqtt_password', 'mqtt_client_id',
      'mqtt_timeout', 'mqtt_local_http',
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

/// Single-broker MQTT service.
/// Uses the factory broker when in factory mode, or the user's saved config.
class MqttConnectivityService extends StateNotifier<MqttConnectionStatus>
    with WidgetsBindingObserver {
  final Ref _ref;
  MqttServerClient? _client;
  StreamSubscription? _messageSubscription;
  bool _cancelled = false;

  MqttConnectivityService(this._ref)
      : super(const MqttConnectionStatus(HubConnectionState.disconnected)) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !this.state.isConnected) {
      debugPrint('[MQTT] App resumed — reconnecting.');
      connect();
    }
  }

  /// Returns the effective config: factory default or user-saved custom.
  MqttConfig _effectiveConfig() {
    final useFactory = _ref.read(mqttUseFactoryProvider);
    return useFactory ? MqttConfig.factoryDefault : _ref.read(mqttConfigProvider);
  }

  /// Connect to the effective broker (factory or custom).
  Future<void> connect() async {
    final config = _effectiveConfig();
    if (!config.isConfigured) {
      debugPrint('[MQTT] No broker configured — skipping connect.');
      return;
    }
    _cancelled = false;
    await _disconnect();
    state = const MqttConnectionStatus(HubConnectionState.connecting);

    try {
      await _connectWith(config);
    } catch (e) {
      final msg = _friendlyError(e, config.host, config.port, config.useTls);
      debugPrint('[MQTT] Connection failed: $e');
      if (!_cancelled) {
        state = MqttConnectionStatus(HubConnectionState.disconnected, msg);
      }
    }
  }

  /// Maps a raw exception to a human-readable message shown in the UI.
  String _friendlyError(dynamic e, String host, int port, bool tls) {
    if (e is SocketException) {
      return 'Cannot reach $host:$port — verify the host address and network connection.';
    }
    if (e is TimeoutException) {
      return 'Connection to $host:$port timed out — broker may be unreachable or overloaded.';
    }
    final msg = e.toString().toLowerCase();
    if (msg.contains('handshake') || msg.contains('certificate') ||
        msg.contains('tls') || msg.contains('ssl')) {
      return tls
          ? 'TLS handshake failed for $host:$port — confirm the broker supports TLS on port $port.'
          : 'Unexpected TLS error on $host:$port — try enabling TLS in settings.';
    }
    if (msg.contains('connack') || msg.contains('refused') ||
        msg.contains('not authorized') || msg.contains('unauthorized')) {
      return 'Broker at $host rejected the connection — check credentials or client ID.';
    }
    return 'Failed to connect to $host:$port — ${e.toString()}';
  }

  Future<void> _connectWith(MqttConfig config) async {
    // Unique client ID per attempt to avoid conflicts on shared brokers.
    final suffix = List.generate(
        6, (_) => Random().nextInt(36).toRadixString(36)).join();
    final effectiveClientId = '${config.clientId}_$suffix';

    _client = MqttServerClient.withPort(config.host, effectiveClientId, config.port)
      ..keepAlivePeriod = 60
      ..onDisconnected = _onDisconnected
      ..autoReconnect = true
      ..logging(on: false);

    if (config.useTls) {
      _client!.secure = true;
      _client!.securityContext = SecurityContext.defaultContext;
      _client!.onBadCertificate = (cert) {
        debugPrint('[MQTT] TLS: certificate rejected — ${cert.subject}');
        return false;
      };
    }

    // Build CONNECT packet.
    // NOTE: do NOT call withWillQos without withWillTopic — MQTT spec §3.1.2.6
    // forbids non-zero Will QoS when Will Flag is 0. Strict brokers reject this.
    final connMsg = MqttConnectMessage()
        .withClientIdentifier(effectiveClientId)
        .startClean();
    if (config.hasCredentials) {
      connMsg.authenticateAs(config.username, config.password);
    }
    _client!.connectionMessage = connMsg;

    await _client!
        .connect()
        .timeout(Duration(seconds: config.connectTimeoutSeconds));

    if (_client!.connectionStatus?.state != MqttConnectionState.connected) {
      final rc = _client!.connectionStatus?.returnCode?.name ?? 'unknown';
      throw Exception('Broker refused connection (CONNACK: $rc)');
    }

    if (_cancelled) {
      _client?.disconnect();
      _client = null;
      return;
    }

    // Detect private-IP brokers (LAN) vs public/cloud brokers.
    final isLocal = _isPrivateAddress(config.host);
    state = MqttConnectionStatus(
      isLocal ? HubConnectionState.connectedLocal : HubConnectionState.connectedCloud,
    );
    debugPrint(
      '[MQTT] Connected → ${config.host}:${config.port} | '
      'TLS: ${config.useTls} | Auth: ${config.hasCredentials} | '
      'ClientId: $effectiveClientId',
    );
    _subscribeToFleet();
  }

  /// Returns true when the host resolves to a private (LAN) address.
  bool _isPrivateAddress(String host) {
    return RegExp(
            r'^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.|localhost$|127\.0\.0\.1$)')
        .hasMatch(host);
  }

  /// Cancel any in-progress connection attempt and disconnect.
  void stopConnection() {
    _cancelled = true;
    _disconnect();
    state = const MqttConnectionStatus(HubConnectionState.disconnected);
    debugPrint('[MQTT] Connection stopped by user.');
  }

  void _subscribeToFleet() {
    _client!.subscribe('devices/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('devices/+/telemetry', MqttQos.atLeastOnce);
    _client!.subscribe('devices/+/announce', MqttQos.atLeastOnce);

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

    switch (messageType) {
      case 'status':
        if (payload == 'offline') {
          _ref.read(deviceManagerProvider.notifier).markDeviceOffline(deviceId);
          debugPrint('[MQTT] Device $deviceId went offline (LWT).');
        }

      case 'telemetry':
        try {
          final map = jsonDecode(payload) as Map<String, dynamic>;
          _ref.read(deviceManagerProvider.notifier).applyTelemetry(deviceId, map);
          debugPrint('[MQTT] Telemetry applied for $deviceId');
        } catch (_) {
          debugPrint('[MQTT] Malformed telemetry from $deviceId: $payload');
        }

      case 'announce':
        try {
          final map = jsonDecode(payload) as Map<String, dynamic>;
          final device = MatterDevice.fromJson(map);
          _ref.read(deviceManagerProvider.notifier).handleAnnounce(device);
          debugPrint('[MQTT] Announce from $deviceId — IP: ${device.localIp}');
        } catch (_) {
          debugPrint('[MQTT] Malformed announce from $deviceId: $payload');
        }
    }
  }

  /// Publish a command to a specific device topic.
  Future<void> publishCommand(String deviceId, String payloadJson) async {
    await publish('devices/$deviceId/command', payloadJson);
  }

  /// Publishes an authenticated broker-reconfiguration command to a device.
  Future<void> publishConfig(String deviceId, String payloadJson) async {
    await publish('devices/$deviceId/config', payloadJson);
  }

  /// General-purpose publish for arbitrary topic routing (OTA, etc.).
  Future<void> publish(String topic, String payloadJson) async {
    if (_client == null || !state.isConnected) {
      debugPrint('[MQTT] Not connected — publish to $topic dropped.');
      return;
    }
    final builder = MqttClientPayloadBuilder()..addString(payloadJson);
    _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void _onDisconnected() {
    if (!_cancelled) {
      state = const MqttConnectionStatus(
        HubConnectionState.disconnected,
        'Connection lost. Will reconnect automatically.',
      );
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _disconnect();
    super.dispose();
  }
}

final mqttServiceProvider =
    StateNotifierProvider<MqttConnectivityService, MqttConnectionStatus>((ref) {
  return MqttConnectivityService(ref);
});
