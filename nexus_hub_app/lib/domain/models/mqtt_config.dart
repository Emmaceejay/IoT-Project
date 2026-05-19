/// Immutable value object holding all broker connection parameters.
/// Broker-agnostic — works with EMQX, Mosquitto, HiveMQ, AWS IoT, etc.
class MqttConfig {
  final String host;
  final int port;
  final bool useTls;
  final String username;
  final String password;
  final String clientId;

  const MqttConfig({
    this.host = '',
    this.port = 1883,
    this.useTls = false,
    this.username = '',
    this.password = '',
    this.clientId = 'nexus_hub_client',
  });

  bool get isConfigured => host.trim().isNotEmpty;
  bool get hasCredentials => username.trim().isNotEmpty;

  MqttConfig copyWith({
    String? host,
    int? port,
    bool? useTls,
    String? username,
    String? password,
    String? clientId,
  }) =>
      MqttConfig(
        host: host ?? this.host,
        port: port ?? this.port,
        useTls: useTls ?? this.useTls,
        username: username ?? this.username,
        password: password ?? this.password,
        clientId: clientId ?? this.clientId,
      );

  Map<String, String> toStorageMap() => {
        'mqtt_host': host,
        'mqtt_port': port.toString(),
        'mqtt_use_tls': useTls.toString(),
        'mqtt_username': username,
        'mqtt_password': password,
        'mqtt_client_id': clientId,
      };

  factory MqttConfig.fromStorageMap(Map<String, String?> map) => MqttConfig(
        host: map['mqtt_host'] ?? '',
        port: int.tryParse(map['mqtt_port'] ?? '') ?? 1883,
        useTls: map['mqtt_use_tls'] == 'true',
        username: map['mqtt_username'] ?? '',
        password: map['mqtt_password'] ?? '',
        clientId: map['mqtt_client_id']?.isNotEmpty == true
            ? map['mqtt_client_id']!
            : 'nexus_hub_client',
      );
}
