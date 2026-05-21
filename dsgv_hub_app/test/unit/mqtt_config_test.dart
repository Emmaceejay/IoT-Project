import 'package:flutter_test/flutter_test.dart';
import 'package:dsgv_hub_app/domain/models/mqtt_config.dart';

void main() {
  group('MqttConfig', () {
    test('default values', () {
      const cfg = MqttConfig();
      expect(cfg.host, '');
      expect(cfg.port, 1883);
      expect(cfg.useTls, false);
      expect(cfg.clientId, 'dsgv_hub_client');
      expect(cfg.localPort, 1883);
      expect(cfg.connectTimeoutSeconds, 10);
      expect(cfg.enableLocalHttp, true);
    });

    test('isConfigured is false for empty host', () {
      expect(const MqttConfig().isConfigured, false);
    });

    test('isConfigured is true when host is set', () {
      expect(const MqttConfig(host: 'broker.test').isConfigured, true);
    });

    test('isConfigured is false for whitespace-only host', () {
      expect(const MqttConfig(host: '   ').isConfigured, false);
    });

    test('hasCredentials reflects non-empty username', () {
      expect(const MqttConfig().hasCredentials, false);
      expect(const MqttConfig(username: 'user').hasCredentials, true);
    });

    test('hasLocalBroker reflects non-empty localHost', () {
      expect(const MqttConfig().hasLocalBroker, false);
      expect(const MqttConfig(localHost: '192.168.1.1').hasLocalBroker, true);
    });

    test('copyWith updates only specified fields', () {
      const cfg = MqttConfig(host: 'a', port: 8883, useTls: true);
      final updated = cfg.copyWith(port: 1883, useTls: false);
      expect(updated.host, 'a'); // unchanged
      expect(updated.port, 1883);
      expect(updated.useTls, false);
    });

    test('toStorageMap serializes all fields as strings', () {
      const cfg = MqttConfig(
        host: 'broker.io',
        port: 8883,
        useTls: true,
        username: 'usr',
        password: 'pw',
        clientId: 'client1',
        localHost: '192.168.1.5',
        localPort: 1883,
        connectTimeoutSeconds: 15,
        enableLocalHttp: false,
      );
      final map = cfg.toStorageMap();
      expect(map['mqtt_host'], 'broker.io');
      expect(map['mqtt_port'], '8883');
      expect(map['mqtt_use_tls'], 'true');
      expect(map['mqtt_username'], 'usr');
      expect(map['mqtt_password'], 'pw');
      expect(map['mqtt_client_id'], 'client1');
      expect(map['mqtt_local_host'], '192.168.1.5');
      expect(map['mqtt_local_port'], '1883');
      expect(map['mqtt_timeout'], '15');
      expect(map['mqtt_local_http'], 'false');
    });

    test('fromStorageMap round-trips with toStorageMap', () {
      const original = MqttConfig(
        host: 'test.broker',
        port: 8883,
        useTls: true,
        username: 'u',
        password: 'p',
        clientId: 'cid',
        localHost: '10.0.0.1',
        localPort: 1884,
        connectTimeoutSeconds: 20,
        enableLocalHttp: false,
      );
      final restored = MqttConfig.fromStorageMap(original.toStorageMap());
      expect(restored.host, original.host);
      expect(restored.port, original.port);
      expect(restored.useTls, original.useTls);
      expect(restored.username, original.username);
      expect(restored.password, original.password);
      expect(restored.clientId, original.clientId);
      expect(restored.localHost, original.localHost);
      expect(restored.localPort, original.localPort);
      expect(restored.connectTimeoutSeconds, original.connectTimeoutSeconds);
      expect(restored.enableLocalHttp, original.enableLocalHttp);
    });

    test('fromStorageMap falls back to defaults for missing/malformed entries', () {
      final cfg = MqttConfig.fromStorageMap({});
      expect(cfg.host, '');
      expect(cfg.port, 1883);
      expect(cfg.connectTimeoutSeconds, 10);
      expect(cfg.enableLocalHttp, true);
      expect(cfg.clientId, 'dsgv_hub_client');
    });

    test('fromStorageMap uses default clientId when stored value is empty', () {
      final cfg = MqttConfig.fromStorageMap({'mqtt_client_id': ''});
      expect(cfg.clientId, 'dsgv_hub_client');
    });
  });
}
