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
  // Cloud broker
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _clientIdCtrl = TextEditingController();
  // Local / LAN broker
  final _localHostCtrl = TextEditingController();
  final _localPortCtrl = TextEditingController();
  // Advanced
  final _timeoutCtrl = TextEditingController();

  bool _useTls = false;
  bool _enableLocalHttp = true;
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
    _localHostCtrl.dispose();
    _localPortCtrl.dispose();
    _timeoutCtrl.dispose();
    super.dispose();
  }

  void _populateFromConfig(MqttConfig config) {
    _hostCtrl.text = config.host;
    _portCtrl.text = config.port.toString();
    _usernameCtrl.text = config.username;
    _clientIdCtrl.text = config.clientId;
    _localHostCtrl.text = config.localHost;
    _localPortCtrl.text = config.localPort.toString();
    _timeoutCtrl.text = config.connectTimeoutSeconds.toString();
    // Never pre-fill password for security
    setState(() {
      _useTls = config.useTls;
      _enableLocalHttp = config.enableLocalHttp;
    });
  }

  void _onTlsToggled(bool value) {
    setState(() {
      _useTls = value;
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
    final rawTimeout = int.tryParse(_timeoutCtrl.text.trim()) ?? 10;

    final config = MqttConfig(
      host: host,
      port: port,
      useTls: _useTls,
      username: _usernameCtrl.text.trim(),
      password: _passwordCtrl.text,
      clientId: _clientIdCtrl.text.trim().isNotEmpty
          ? _clientIdCtrl.text.trim()
          : 'nexus_hub_client',
      localHost: _localHostCtrl.text.trim(),
      localPort: int.tryParse(_localPortCtrl.text.trim()) ?? 1883,
      connectTimeoutSeconds: rawTimeout.clamp(3, 60),
      enableLocalHttp: _enableLocalHttp,
    );

    await ref.read(mqttConfigProvider.notifier).save(config);
    await ref.read(mqttServiceProvider.notifier).connect();

    if (!mounted) return;
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  void _stopConnection() {
    ref.read(mqttServiceProvider.notifier).stopConnection();
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
    // Populate form from storage on first load only
    ref.listen<MqttConfig>(mqttConfigProvider, (_, config) {
      if (!_initialized && config.isConfigured) {
        _initialized = true;
        _populateFromConfig(config);
      }
    });

    final status = ref.watch(mqttServiceProvider);
    final isConnecting = status.state == HubConnectionState.connecting;

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
          _StatusBadge(status: status),
          const SizedBox(height: 28),

          // ── Cloud Broker ───────────────────────────────────────────────
          _sectionHeader('Cloud Broker'),
          _field('Host / IP', _hostCtrl, Icons.dns_outlined,
              hint: 'e.g. broker.hivemq.com or 192.168.1.10'),
          const SizedBox(height: 12),
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

          // ── Local Broker / LAN Fallback ────────────────────────────────
          _sectionHeader('Local Broker  (LAN fallback)'),
          _field('Local Host / IP', _localHostCtrl, Icons.router_outlined,
              hint: 'e.g. 192.168.1.5 — same router as devices'),
          const SizedBox(height: 12),
          _field('Local Port', _localPortCtrl, Icons.numbers,
              isNumber: true, hint: '1883'),
          const SizedBox(height: 12),
          _LocalHttpToggleTile(
            value: _enableLocalHttp,
            onChanged: (v) => setState(() => _enableLocalHttp = v),
          ),
          const SizedBox(height: 20),

          // ── Advanced ───────────────────────────────────────────────────
          _sectionHeader('Advanced'),
          _field('Client ID', _clientIdCtrl, Icons.fingerprint,
              hint: 'nexus_hub_client'),
          const SizedBox(height: 12),
          _field('Connection Timeout (s)', _timeoutCtrl, Icons.timer_outlined,
              isNumber: true, hint: '10'),
          const SizedBox(height: 32),

          // ── Action Buttons ─────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _saved ? Colors.greenAccent : const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: isConnecting ? null : _saveAndConnect,
                  icon: isConnecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black),
                        )
                      : Icon(_saved ? Icons.check : Icons.wifi_tethering),
                  label: Text(
                    isConnecting
                        ? 'Connecting...'
                        : _saved
                            ? 'Saved!'
                            : 'Save & Connect',
                  ),
                ),
              ),
              if (isConnecting) ...[
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 20),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _stopConnection,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop'),
                ),
              ],
            ],
          ),

          // ── Error Message ──────────────────────────────────────────────
          if (status.errorMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Colors.redAccent.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.redAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      status.errorMessage!,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],

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

// ── Local HTTP Toggle Tile ───────────────────────────────────────────────────

class _LocalHttpToggleTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _LocalHttpToggleTile({required this.value, required this.onChanged});

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
                ? Colors.greenAccent.withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  value ? Icons.wifi : Icons.wifi_off,
                  size: 18,
                  color: value ? Colors.greenAccent : Colors.white38,
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value ? 'Local HTTP: ON' : 'Local HTTP: OFF',
                      style: TextStyle(
                        color: value ? Colors.greenAccent : Colors.white38,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Direct control on same WiFi',
                      style: TextStyle(
                        color: value
                            ? Colors.greenAccent.withValues(alpha: 0.6)
                            : Colors.white24,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Colors.greenAccent,
              activeTrackColor: Colors.greenAccent.withValues(alpha: 0.4),
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
  final MqttConnectionStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status.state) {
      HubConnectionState.connectedCloud => (
        'Connected · Cloud Broker',
        const Color(0xFF00E5FF),
        Icons.cloud_done_outlined,
      ),
      HubConnectionState.connectedLocal => (
        'Connected · Local Broker',
        Colors.greenAccent,
        Icons.router_outlined,
      ),
      HubConnectionState.connectedDirect => (
        'Connected · Direct (HTTP)',
        Colors.lightGreenAccent,
        Icons.wifi_tethering,
      ),
      HubConnectionState.connecting => (
        'Connecting...',
        Colors.orangeAccent,
        Icons.sync,
      ),
      HubConnectionState.disconnected => (
        'Disconnected',
        Colors.redAccent,
        Icons.wifi_off,
      ),
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
          const SizedBox(width: 10),
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
