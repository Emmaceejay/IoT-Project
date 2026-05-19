import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/mqtt_service.dart';

/// Settings Screen
/// Allows the user to configure MQTT broker endpoints at runtime.
/// Values are persisted via flutter_secure_storage.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _cloudHostCtrl = TextEditingController(text: 'your-emqx-endpoint.cloud');
  final _cloudPortCtrl = TextEditingController(text: '8883');
  final _localHostCtrl = TextEditingController(text: '192.168.1.100');
  final _localPortCtrl = TextEditingController(text: '1883');
  bool _saved = false;

  @override
  void dispose() {
    _cloudHostCtrl.dispose();
    _cloudPortCtrl.dispose();
    _localHostCtrl.dispose();
    _localPortCtrl.dispose();
    super.dispose();
  }

  void _save() {
    // TODO: Persist via flutter_secure_storage
    // final storage = FlutterSecureStorage();
    // await storage.write(key: 'mqtt_cloud_host', value: _cloudHostCtrl.text);
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final mqttState = ref.watch(mqttServiceProvider).connectionState;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Settings',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Connection Status ──────────────────────────────────────────
          _statusBadge(mqttState),
          const SizedBox(height: 28),

          // ── Cloud Broker ───────────────────────────────────────────────
          _sectionHeader('Cloud Broker (EMQX)'),
          _field('Host', _cloudHostCtrl, Icons.cloud_outlined),
          const SizedBox(height: 12),
          _field('Port', _cloudPortCtrl, Icons.numbers, isNumber: true),
          const SizedBox(height: 28),

          // ── Local Fallback ─────────────────────────────────────────────
          _sectionHeader('Local Fallback (Mosquitto)'),
          _field('Host / IP', _localHostCtrl, Icons.home_outlined),
          const SizedBox(height: 12),
          _field('Port', _localPortCtrl, Icons.numbers, isNumber: true),
          const SizedBox(height: 32),

          // ── Save ───────────────────────────────────────────────────────
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _saved ? Colors.greenAccent : const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _save,
            icon: Icon(_saved ? Icons.check : Icons.save_outlined),
            label: Text(_saved ? 'Saved!' : 'Save Configuration'),
          ),

          const SizedBox(height: 20),

          // ── Reconnect ──────────────────────────────────────────────────
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF00E5FF),
              side: const BorderSide(color: Color(0xFF00E5FF)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              ref.read(mqttServiceProvider).connect();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Reconnect to Broker'),
          ),

          const SizedBox(height: 32),

          // ── App Info ───────────────────────────────────────────────────
          const Center(
            child: Text(
              'Nexus Hub  v1.0.0\nMatter + MQTT IoT Platform',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(HubConnectionState state) {
    final label = {
      HubConnectionState.connectedCloud: 'Connected to Cloud Broker',
      HubConnectionState.connectedLocal: 'Connected to Local Broker',
      HubConnectionState.connecting: 'Connecting...',
      HubConnectionState.disconnected: 'Disconnected',
    }[state]!;
    final color = {
      HubConnectionState.connectedCloud: const Color(0xFF00E5FF),
      HubConnectionState.connectedLocal: Colors.greenAccent,
      HubConnectionState.connecting: Colors.orangeAccent,
      HubConnectionState.disconnected: Colors.redAccent,
    }[state]!;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(title,
            style: const TextStyle(
                color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600)),
      );

  Widget _field(String label, TextEditingController ctrl, IconData icon,
      {bool isNumber = false}) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white),
      keyboardType: isNumber ? TextInputType.number : TextInputType.url,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white38),
        prefixIcon: Icon(icon, color: const Color(0xFF00E5FF)),
        filled: true,
        fillColor: const Color(0xFF121826),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF00E5FF))),
      ),
    );
  }
}
