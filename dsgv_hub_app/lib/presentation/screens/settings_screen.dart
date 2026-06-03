import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/mqtt_config.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/mqtt_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Broker fields
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _clientIdCtrl = TextEditingController();
  // Advanced
  final _timeoutCtrl = TextEditingController();

  bool _useTls = false;
  bool _enableLocalHttp = true;
  bool _showPassword = false;
  bool _saved = false;
  bool _configInitialized = false;
  bool _brokerSyncInProgress = false;

  static const int _defaultPlainPort = 1883;
  static const int _defaultTlsPort = 8883;

  @override
  void initState() {
    super.initState();
    _portCtrl.text = _defaultPlainPort.toString();
    _clientIdCtrl.text = 'dsgv_hub_client';
    _timeoutCtrl.text = '10';

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _configInitialized) return;
      final config = ref.read(mqttConfigProvider);
      if (config.isConfigured) {
        _configInitialized = true;
        _populateFromConfig(config);
      }
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _clientIdCtrl.dispose();
    _timeoutCtrl.dispose();
    super.dispose();
  }

  void _populateFromConfig(MqttConfig config) {
    _hostCtrl.text = config.host;
    _portCtrl.text = config.port.toString();
    _usernameCtrl.text = config.username;
    _clientIdCtrl.text = config.clientId;
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

  /// User tapped "Use custom broker" — unlock the form fields.
  Future<void> _switchToCustomMode() async {
    await ref.read(mqttUseFactoryProvider.notifier).setFactoryMode(false);
    // Pre-fill form with sensible defaults if nothing has been saved yet
    final saved = ref.read(mqttConfigProvider);
    if (!saved.isConfigured) {
      _portCtrl.text = _defaultPlainPort.toString();
      setState(() {
        _useTls = false;
        _enableLocalHttp = true;
      });
    } else {
      _populateFromConfig(saved);
    }
  }

  /// User tapped "Revert to manufacturer server" — lock the form back.
  Future<void> _revertToFactory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF121826),
        title: const Text('Use manufacturer server?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Your custom broker settings will be kept but the app will reconnect '
          'to the manufacturer server. You can switch back to custom at any time.',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Use manufacturer server'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(mqttUseFactoryProvider.notifier).setFactoryMode(true);
    await ref.read(mqttServiceProvider.notifier).connect();
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
          : 'dsgv_hub_client',
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

  int _tokenDeviceCount() {
    final devices = ref.read(deviceManagerProvider).valueOrNull ?? [];
    return devices.where((d) => d.authToken != null).length;
  }

  Future<void> _onPushBrokerTapped() async {
    final count = _tokenDeviceCount();
    if (count == 0) return;

    final host = _hostCtrl.text.trim();
    if (host.isEmpty) {
      _showError('Save broker settings first before pushing to devices.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF121826),
        title: const Text('Change Device Broker?',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orangeAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Colors.orangeAccent.withValues(alpha: 0.4)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.orangeAccent, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Changing the broker will redirect your devices away '
                      'from the manufacturer\'s server.\n\n'
                      'Without a factory reset, they cannot be reconnected '
                      'to the original server from this screen.',
                      style: TextStyle(
                          color: Colors.orangeAccent, fontSize: 13, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'This will send the new broker ($host) to $count device(s). '
              'Each device will reconnect without interrupting relay outputs.',
              style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Change Broker'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final finalConfirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF121826),
        title: const Text('Are you sure?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This action cannot be undone from this screen without a factory '
          'reset on each device. Tap "Confirm Change" to proceed.',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Go Back',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm Change'),
          ),
        ],
      ),
    );

    if (finalConfirmed != true || !mounted) return;

    setState(() => _brokerSyncInProgress = true);
    try {
      final sent =
          await ref.read(deviceManagerProvider.notifier).pushBrokerConfig();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Broker config sent to $sent device(s). They will reconnect shortly.'),
        backgroundColor: Colors.greenAccent.shade700,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _brokerSyncInProgress = false);
    }
  }

  Future<void> _onRevertToFactoryTapped() async {
    final count = _tokenDeviceCount();
    if (count == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF121826),
        title: const Text('Restore Factory Broker?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'This will reconnect $count device(s) to the manufacturer\'s '
          'original MQTT server. Use this to undo a previous broker change.',
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore Factory'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _brokerSyncInProgress = true);
    try {
      final devices = ref.read(deviceManagerProvider).valueOrNull ?? [];
      int sent = 0;
      for (final d in devices) {
        if (d.authToken == null) continue;
        await ref.read(deviceManagerProvider.notifier)
            .revertDeviceBroker(d.uniqueDeviceId, d.authToken!);
        sent++;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Factory broker restore sent to $sent device(s).'),
        backgroundColor: const Color(0xFF00E5FF).withValues(alpha: 0.85),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _brokerSyncInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<MqttConfig>(mqttConfigProvider, (_, config) {
      if (!_configInitialized) {
        _configInitialized = true;
        _populateFromConfig(config);
      }
    });

    final status = ref.watch(mqttServiceProvider);
    final useFactory = ref.watch(mqttUseFactoryProvider);
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
          _StatusBadge(status: status, useFactory: useFactory),
          const SizedBox(height: 24),

          // ── Broker Source Tile ─────────────────────────────────────────
          _BrokerSourceTile(
            useFactory: useFactory,
            onSwitchToCustom: _switchToCustomMode,
            onRevertToFactory: _revertToFactory,
          ),
          const SizedBox(height: 24),

          // ── Custom Broker Form (only visible in custom mode) ───────────
          if (!useFactory) ...[
            _sectionHeader('Broker'),
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

            _sectionHeader('Authentication  (optional)'),
            _field('Username', _usernameCtrl, Icons.person_outline,
                hint: 'Leave blank for anonymous'),
            const SizedBox(height: 12),
            _passwordField(),
            const SizedBox(height: 20),

            _sectionHeader('Advanced'),
            _field('Client ID', _clientIdCtrl, Icons.fingerprint,
                hint: 'dsgv_hub_client'),
            const SizedBox(height: 12),
            _field('Connection Timeout (s)', _timeoutCtrl, Icons.timer_outlined,
                isNumber: true, hint: '10'),
            const SizedBox(height: 12),
            _LocalHttpToggleTile(
              value: _enableLocalHttp,
              onChanged: (v) => setState(() => _enableLocalHttp = v),
            ),
            const SizedBox(height: 28),

            // ── Action Buttons ─────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _saved
                          ? Colors.greenAccent
                          : const Color(0xFF00E5FF),
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

            // ── Error Message ──────────────────────────────────────────
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
          ],

          // ── Device Broker Sync (always visible) ────────────────────────
          _sectionHeader('Device Broker Sync'),
          _BrokerSyncSection(
            tokenDeviceCount: _tokenDeviceCount(),
            inProgress: _brokerSyncInProgress,
            onPush: _onPushBrokerTapped,
            onRevert: _onRevertToFactoryTapped,
          ),
          const SizedBox(height: 32),

          // ── App Info ───────────────────────────────────────────────────
          const Center(
            child: Text(
              'DSGV Hub  v1.0.0\nC2C + WiFi/MQTT IoT Platform',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
          ),
          const SizedBox(height: 20),
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

// ── Broker Source Tile ────────────────────────────────────────────────────────
// Shows either "manufacturer server" (locked) or "custom broker" (active).

class _BrokerSourceTile extends StatelessWidget {
  final bool useFactory;
  final VoidCallback onSwitchToCustom;
  final VoidCallback onRevertToFactory;

  const _BrokerSourceTile({
    required this.useFactory,
    required this.onSwitchToCustom,
    required this.onRevertToFactory,
  });

  @override
  Widget build(BuildContext context) {
    if (useFactory) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified_outlined,
                          size: 13, color: Color(0xFF00E5FF)),
                      SizedBox(width: 4),
                      Text(
                        'Manufacturer',
                        style: TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Connected to DSGV managed server',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Your devices are managed by DSGV infrastructure. '
              'No configuration required.',
              style:
                  TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white54,
                side: const BorderSide(color: Colors.white12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: onSwitchToCustom,
              icon: const Icon(Icons.edit_outlined, size: 15),
              label: const Text('Use custom broker',
                  style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
    }

    // Custom mode tile
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: Colors.orangeAccent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.settings_ethernet,
              color: Colors.orangeAccent, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Custom broker active',
              style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: const Color(0xFF00E5FF),
            ),
            onPressed: onRevertToFactory,
            child: const Text('↩ Manufacturer',
                style: TextStyle(fontSize: 12)),
          ),
        ],
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

// ── Broker Sync Section ───────────────────────────────────────────────────────

class _BrokerSyncSection extends StatelessWidget {
  final int tokenDeviceCount;
  final bool inProgress;
  final VoidCallback onPush;
  final VoidCallback onRevert;

  const _BrokerSyncSection({
    required this.tokenDeviceCount,
    required this.inProgress,
    required this.onPush,
    required this.onRevert,
  });

  @override
  Widget build(BuildContext context) {
    final hasDevices = tokenDeviceCount > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orangeAccent.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: Colors.orangeAccent.withValues(alpha: 0.35)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: Colors.orangeAccent, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Changing the broker redirects devices away from the '
                  "manufacturer's server. Without a factory reset, they "
                  'cannot be reconnected to the original server from here.',
                  style: TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 12,
                      height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          hasDevices
              ? '$tokenDeviceCount provisioned device(s) can receive broker changes.'
              : 'No provisioned devices found. Pair a device first.',
          style: TextStyle(
              color: hasDevices ? Colors.white54 : Colors.white24,
              fontSize: 12),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.redAccent.withValues(alpha: 0.3),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: (!hasDevices || inProgress) ? null : onPush,
          icon: inProgress
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.sync_alt, size: 18),
          label: Text(inProgress
              ? 'Sending…'
              : 'Push broker to all devices ($tokenDeviceCount)'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor:
                hasDevices ? const Color(0xFF00E5FF) : Colors.white24,
            side: BorderSide(
              color: hasDevices
                  ? const Color(0xFF00E5FF).withValues(alpha: 0.5)
                  : Colors.white12,
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: (!hasDevices || inProgress) ? null : onRevert,
          icon: const Icon(Icons.restore, size: 18),
          label: const Text('Restore factory broker'),
        ),
      ],
    );
  }
}

// ── Status Badge ─────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final MqttConnectionStatus status;
  final bool useFactory;

  const _StatusBadge({required this.status, required this.useFactory});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status.state) {
      HubConnectionState.connectedCloud => (
        useFactory
            ? 'Connected · Manufacturer Server'
            : 'Connected · Custom Broker',
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
