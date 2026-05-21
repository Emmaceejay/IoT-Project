/// Immutable value object holding all MQTT + transport configuration.
/// Broker-agnostic — works with EMQX, Mosquitto, HiveMQ, AWS IoT, etc.
class MqttConfig {
  // ── Primary Broker ───────────────────────────────────────────────────────
  final String host;
  final int port;
  final bool useTls;
  final String username;
  final String password;
  final String clientId;

  // ── Local MQTT Fallback (same router, no internet needed) ────────────────
  final String localHost;
  final int localPort;

  // ── Connection Behaviour ─────────────────────────────────────────────────
  final int connectTimeoutSeconds;

  // ── Local HTTP Transport (Tasmota-style direct-device control) ───────────
  final bool enableLocalHttp;

  const MqttConfig({
    this.host = '',
    this.port = 1883,
    this.useTls = false,
    this.username = '',
    this.password = '',
    this.clientId = 'dsgv_hub_client',
    this.localHost = '',
    this.localPort = 1883,
    this.connectTimeoutSeconds = 10,
    this.enableLocalHttp = true,
  });

  bool get isConfigured => host.trim().isNotEmpty;
  bool get hasCredentials => username.trim().isNotEmpty;
  bool get hasLocalBroker => localHost.trim().isNotEmpty;

  MqttConfig copyWith({
    String? host,
    int? port,
    bool? useTls,
    String? username,
    String? password,
    String? clientId,
    String? localHost,
    int? localPort,
    int? connectTimeoutSeconds,
    bool? enableLocalHttp,
  }) =>
      MqttConfig(
        host: host ?? this.host,
        port: port ?? this.port,
        useTls: useTls ?? this.useTls,
        username: username ?? this.username,
        password: password ?? this.password,
        clientId: clientId ?? this.clientId,
        localHost: localHost ?? this.localHost,
        localPort: localPort ?? this.localPort,
        connectTimeoutSeconds:
            connectTimeoutSeconds ?? this.connectTimeoutSeconds,
        enableLocalHttp: enableLocalHttp ?? this.enableLocalHttp,
      );

  Map<String, String> toStorageMap() => {
        'mqtt_host': host,
        'mqtt_port': port.toString(),
        'mqtt_use_tls': useTls.toString(),
        'mqtt_username': username,
        'mqtt_password': password,
        'mqtt_client_id': clientId,
        'mqtt_local_host': localHost,
        'mqtt_local_port': localPort.toString(),
        'mqtt_timeout': connectTimeoutSeconds.toString(),
        'mqtt_local_http': enableLocalHttp.toString(),
      };

  factory MqttConfig.fromStorageMap(Map<String, String?> map) => MqttConfig(
        host: map['mqtt_host'] ?? '',
        port: int.tryParse(map['mqtt_port'] ?? '') ?? 1883,
        useTls: map['mqtt_use_tls'] == 'true',
        username: map['mqtt_username'] ?? '',
        password: map['mqtt_password'] ?? '',
        clientId: map['mqtt_client_id']?.isNotEmpty == true
            ? map['mqtt_client_id']!
            : 'dsgv_hub_client',
        localHost: map['mqtt_local_host'] ?? '',
        localPort: int.tryParse(map['mqtt_local_port'] ?? '') ?? 1883,
        connectTimeoutSeconds:
            int.tryParse(map['mqtt_timeout'] ?? '') ?? 10,
        enableLocalHttp: map['mqtt_local_http'] != 'false',
      );
}
