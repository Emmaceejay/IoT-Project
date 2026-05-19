import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/mqtt_config.dart';
import '../../domain/services/mqtt_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _clientIdCtrl = TextEditingController();

  bool _useTls = false;
  bool _showPassword = false;
  bool _saved = false;
  bool _initialized = false;

  static const int _defaultPlainPort = 1883;
  static const int _defaultTlsPort = 8883;

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _clientIdCtrl.dispose();
    super.dispose();
  }

  void _populateFromConfig(MqttConfig config) {
    _hostCtrl.text = config.host;
    _portCtrl.text = config.port.toString();
    _usernameCtrl.text = config.username;
    _clientIdCtrl.text = config.clientId;
    // Never pre-fill password into the field for security
    setState(() => _useTls = config.useTls);
  }

  void _onTlsToggled(bool value) {
    setState(() {
      _useTls = value;
      // Auto-switch port only when the user hasn't customised it
      final currentPort = int.tryParse(_portCtrl.text) ?? _defaultPlainPort;
      if (!value && currentPort == _defaultTlsPort) {
        _portCtrl.text = _defaultPlainPort.toString();
      } else if (value && currentPort == _defaultPlainPort) {
        _portCtrl.text = _defaultTlsPort.toString();
      }
    });
  }

  Future<void> _saveAndConnect() async {
    final host = _hostCtrl.text.trim();
    if (host.isEmpty) {
      _showError('Broker host cannot be empty.');
      return;
    }
    final port = int.tryParse(_portCtrl.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _showError('Port must be a number between 1 and 65535.');
      return;
    }

    final config = MqttConfig(
      host: host,
      port: port,
      useTls: _useTls,
      username: _usernameCtrl.text.trim(),
      password: _passwordCtrl.text,
      clientId: _clientIdCtrl.text.trim().isNotEmpty
          ? _clientIdCtrl.text.trim()
          : 'nexus_hub_client',
    );

    await ref.read(mqttConfigProvider.notifier).save(config);
    await ref.read(mqttServiceProvider.notifier).connect();

    if (!mounted) return;
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Populate form fields from storage on first load
    ref.listen<MqttConfig>(mqttConfigProvider, (_, config) {
      if (!_initialized && config.isConfigured) {
        _initialized = true;
        _populateFromConfig(config);
      }
    });

    final connectionState = ref.watch(mqttServiceProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Connection Status Badge ────────────────────────────────────
          _StatusBadge(state: connectionState),
          const SizedBox(height: 28),

          // ── Broker Configuration ───────────────────────────────────────
          _sectionHeader('Broker Configuration'),
          _field('Host / IP', _hostCtrl, Icons.dns_outlined,
              hint: 'e.g. broker.hivemq.com or 192.168.1.10'),
          const SizedBox(height: 12),

          // Port + TLS toggle on same row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: _field('Port', _portCtrl, Icons.numbers,
                    isNumber: true, hint: _useTls ? '8883' : '1883'),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: _TlsToggleTile(
                  value: _useTls,
                  onChanged: _onTlsToggled,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Authentication (optional) ──────────────────────────────────
          _sectionHeader('Authentication  (optional)'),
          _field('Username', _usernameCtrl, Icons.person_outline,
              hint: 'Leave blank for anonymous'),
          const SizedBox(height: 12),
          _passwordField(),
          const SizedBox(height: 20),

          // ── Advanced ───────────────────────────────────────────────────
          _sectionHeader('Advanced'),
          _field('Client ID', _clientIdCtrl, Icons.fingerprint,
              hint: 'nexus_hub_client'),
          const SizedBox(height: 32),

          // ── Save & Connect ─────────────────────────────────────────────
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _saved ? Colors.greenAccent : const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed:
                connectionState == HubConnectionState.connecting ? null : _saveAndConnect,
            icon: connectionState == HubConnectionState.connecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.black),
                  )
                : Icon(_saved ? Icons.check : Icons.wifi_tethering),
            label: Text(
              connectionState == HubConnectionState.connecting
                  ? 'Connecting...'
                  : _saved
                      ? 'Saved & Connected!'
                      : 'Save & Connect',
            ),
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

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          title,
          style: const TextStyle(
              color: Colors.white54,
              fontSize: 13,
              fontWeight: FontWeight.w600),
        ),
      );

  Widget _field(
    String label,
    TextEditingController ctrl,
    IconData icon, {
    bool isNumber = false,
    String? hint,
  }) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white),
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
        labelStyle: const TextStyle(color: Colors.white38),
        prefixIcon: Icon(icon, color: const Color(0xFF00E5FF)),
        filled: true,
        fillColor: const Color(0xFF121826),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF00E5FF))),
      ),
    );
  }

  Widget _passwordField() {
    return TextField(
      controller: _passwordCtrl,
      style: const TextStyle(color: Colors.white),
      obscureText: !_showPassword,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: 'Password',
        hintText: 'Leave blank for anonymous',
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
        labelStyle: const TextStyle(color: Colors.white38),
        prefixIcon:
            const Icon(Icons.lock_outline, color: Color(0xFF00E5FF)),
        suffixIcon: IconButton(
          icon: Icon(
            _showPassword ? Icons.visibility_off : Icons.visibility,
            color: Colors.white38,
          ),
          onPressed: () => setState(() => _showPassword = !_showPassword),
        ),
        filled: true,
        fillColor: const Color(0xFF121826),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF00E5FF))),
      ),
    );
  }
}

// ── TLS Toggle Tile ─────────────────────────────────────────────────────────

class _TlsToggleTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _TlsToggleTile({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: value
                ? const Color(0xFF00E5FF).withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  value ? Icons.lock : Icons.lock_open,
                  size: 18,
                  color: value ? const Color(0xFF00E5FF) : Colors.white38,
                ),
                const SizedBox(width: 6),
                Text(
                  value ? 'TLS ON' : 'TLS OFF',
                  style: TextStyle(
                    color: value ? const Color(0xFF00E5FF) : Colors.white38,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: const Color(0xFF00E5FF),
              activeTrackColor: const Color(0xFF00E5FF).withValues(alpha: 0.4),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Status Badge ─────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final HubConnectionState state;

  const _StatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      HubConnectionState.connected => ('Connected to Broker', const Color(0xFF00E5FF)),
      HubConnectionState.connecting => ('Connecting...', Colors.orangeAccent),
      HubConnectionState.disconnected => ('Disconnected', Colors.redAccent),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6)
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
