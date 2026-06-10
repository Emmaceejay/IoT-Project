import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../domain/services/ble_provisioning_service.dart';
import '../../domain/services/device_manager.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

/// Provisions a DSGV device by connecting the phone to the device's Wi-Fi AP
/// (DSGV_Setup_XXXXXX) and sending credentials via a secured HTTP endpoint.
///
/// SECURITY MODEL
/// ──────────────
/// • The device AP is password-protected; the password is derived from the
///   6-char device code that only someone with physical access to the label
///   or QR code can read.
/// • Every HTTP request includes an X-DSGV-Token header derived from the same
///   code. The firmware validates this header and returns 403 if it is absent
///   or wrong — a browser cannot discover or supply it.
/// • The endpoint serves no HTML on GET, so a browser landing on the IP cannot
///   build or submit a form.
class ApProvisioningScreen extends ConsumerStatefulWidget {
  const ApProvisioningScreen({super.key});

  @override
  ConsumerState<ApProvisioningScreen> createState() =>
      _ApProvisioningScreenState();
}

class _ApProvisioningScreenState extends ConsumerState<ApProvisioningScreen> {
  // ── Device identification ────────────────────────────────────────────────
  String? _deviceName; // "DSGVHub_A1B2C3"
  bool _showQrScanner = false;
  final _pairCodeCtrl = TextEditingController();
  final _scannerCtrl = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  ProvisioningDeviceInfo? _deviceInfo;

  // ── AP connectivity polling ──────────────────────────────────────────────
  Timer? _pollTimer;
  bool _apConnected = false;

  // ── Provisioning form ────────────────────────────────────────────────────
  final _assignedNameCtrl = TextEditingController();
  final _ssidCtrl = TextEditingController();
  final _wifiPassCtrl = TextEditingController();
  bool _obscureWifiPass = true;

  // ── Result state ─────────────────────────────────────────────────────────
  bool _isSending = false;
  String? _statusMessage;
  bool _isSuccess = false;

  // ── Derived AP credentials (deterministic from device code) ──────────────

  String? get _deviceCode {
    if (_deviceName == null) return null;
    final i = _deviceName!.lastIndexOf('_');
    if (i < 0 || i + 1 >= _deviceName!.length) return null;
    return _deviceName!.substring(i + 1).toUpperCase();
  }

  String? get _apSsid {
    final c = _deviceCode;
    return c != null ? 'DSGV_Setup_$c' : null;
  }

  // AP password: "dsgv_" + code in lowercase — short, memorable, derivable
  // only from physical access to the device label.
  String? get _apPassword {
    final c = _deviceCode;
    return c != null ? 'dsgv_${c.toLowerCase()}' : null;
  }

  // HTTP token used in X-DSGV-Token header — firmware validates this.
  String? get _httpToken {
    final c = _deviceCode;
    return c != null ? 'DSGV_$c' : null;
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pairCodeCtrl.dispose();
    _assignedNameCtrl.dispose();
    _ssidCtrl.dispose();
    _wifiPassCtrl.dispose();
    _scannerCtrl.dispose();
    super.dispose();
  }

  // ── Device identification handlers ───────────────────────────────────────

  void _onBarcodeDetected(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    if (raw.startsWith('dsgv://provision')) {
      final uri = Uri.tryParse(raw);
      final name = uri?.queryParameters['name'];
      if (name != null && name.isNotEmpty) {
        _scannerCtrl.stop();
        _confirmDevice(name);
        return;
      }
    }
    setState(() =>
        _statusMessage = 'Unrecognised QR. Scan the DSGV provisioning label.');
  }

  void _submitPairCode() {
    final code = _pairCodeCtrl.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(
          () => _statusMessage = 'Enter the 6-character code from the device label.');
      return;
    }
    _confirmDevice('DSGVHub_$code');
  }

  void _confirmDevice(String name) {
    setState(() {
      _deviceName = name;
      _showQrScanner = false;
      _statusMessage = null;
    });
    _startPolling();
    _fetchDeviceInfo(name);
  }

  Future<void> _fetchDeviceInfo(String name) async {
    final info = await BleProvisioningService.fetchProvisioningData(name);
    if (mounted) setState(() => _deviceInfo = info);
  }

  void _resetDevice() {
    _pollTimer?.cancel();
    setState(() {
      _deviceName = null;
      _deviceInfo = null;
      _apConnected = false;
      _statusMessage = null;
      _isSending = false;
      _isSuccess = false;
    });
  }

  // ── AP connectivity polling ──────────────────────────────────────────────

  void _startPolling() {
    _pollTimer?.cancel();
    _apConnected = false;
    _pollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _checkApReachable());
  }

  Future<void> _checkApReachable() async {
    if (_apConnected || !mounted) return;
    try {
      final res = await http
          .get(
            Uri.parse('http://192.168.4.1/ping'),
            headers: {'X-DSGV-Token': _httpToken ?? ''},
          )
          .timeout(const Duration(seconds: 1));
      // Any sub-500 response means the device HTTP server is reachable.
      if (res.statusCode < 500 && mounted) {
        _pollTimer?.cancel();
        setState(() => _apConnected = true);
      }
    } catch (_) {
      // Still connecting — next tick will retry.
    }
  }

  // ── Provisioning ─────────────────────────────────────────────────────────

  Future<void> _sendCredentials() async {
    if (_ssidCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Enter your home Wi-Fi network name.');
      return;
    }
    if (_assignedNameCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Enter a name for this device.');
      return;
    }

    setState(() {
      _isSending = true;
      _statusMessage = 'Sending credentials to device…';
      _isSuccess = false;
    });

    try {
      final info = _deviceInfo;
      final body = <String, dynamic>{
        'ssid': _ssidCtrl.text.trim(),
        'password': _wifiPassCtrl.text,
        if (info != null) 'device_type': info.deviceType,
        if (info != null) 'capabilities': info.capabilities,
        if (info != null) 'relay_count': info.relayCount,
      };

      final response = await http
          .post(
            Uri.parse('http://192.168.4.1/provision'),
            headers: {
              'Content-Type': 'application/json',
              'X-DSGV-Token': _httpToken ?? '',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        if (json['status'] == 'ok') {
          final authToken = json['auth_token'] as String?;
          final deviceId = json['device_id'] as String?;
          if (authToken != null && deviceId != null) {
            final mgr = ref.read(deviceManagerProvider.notifier);
            mgr.setPendingToken(deviceId, authToken);
            mgr.setPendingBleName(deviceId, _deviceName!);
            if (_assignedNameCtrl.text.trim().isNotEmpty) {
              mgr.setPendingName(deviceId, _assignedNameCtrl.text.trim());
            }
            mgr.registerDevice(deviceId, authToken);
          }
          setState(() {
            _isSending = false;
            _isSuccess = true;
            _statusMessage =
                'Credentials sent! The device is rebooting and will join '
                'your network. Reconnect your phone to your home Wi-Fi — '
                'the device will appear in the app within ~30 seconds.';
          });
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) Navigator.of(context).pop();
        } else {
          final reason =
              (json['reason'] as String? ?? 'unknown').replaceAll('_', ' ');
          setState(() {
            _isSending = false;
            _statusMessage = 'Device rejected the request: $reason.';
          });
        }
      } else if (response.statusCode == 403) {
        setState(() {
          _isSending = false;
          _statusMessage =
              'Authorisation failed. Make sure you are connected to '
              'the correct device hotspot.';
        });
      } else {
        setState(() {
          _isSending = false;
          _statusMessage =
              'Unexpected response (HTTP ${response.statusCode}). Try again.';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _apConnected = false;
        _statusMessage =
            'Request timed out. Make sure your phone is still connected '
            'to the device hotspot, then try again.';
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _statusMessage =
            'Could not reach device: ${e.toString().split(':').first}.';
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Pair via Device Hotspot',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_deviceName == null) ...[
              _buildIntroCard(),
              const SizedBox(height: 24),
              _buildIdentifySection(),
            ] else ...[
              _buildDeviceCard(),
              const SizedBox(height: 20),
              _buildApConnectionCard(),
              const SizedBox(height: 20),
              _buildProvisioningForm(),
            ],
            if (_statusMessage != null) ...[
              const SizedBox(height: 16),
              _buildStatusBanner(),
            ],
            const SizedBox(height: 32),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  // ── Widget helpers ────────────────────────────────────────────────────────

  Widget _buildIntroCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.35)),
      ),
      child: const Row(
        children: [
          Icon(Icons.wifi_tethering, color: Colors.tealAccent, size: 32),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No Bluetooth needed',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15),
                ),
                SizedBox(height: 4),
                Text(
                  'Your phone connects directly to the device\'s Wi-Fi '
                  'hotspot, and this app sends the credentials securely '
                  'over a private local channel.',
                  style: TextStyle(
                      color: Colors.white54, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentifySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Step 1 — Identify your device',
          style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
        ),
        const SizedBox(height: 8),
        const Text(
          'Scan the QR label or enter the 6-character code printed on the device.',
          style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 16),

        if (_showQrScanner) ...[
          _buildQrSection(),
        ] else ...[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.tealAccent,
              side: const BorderSide(color: Colors.tealAccent),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('Scan QR Code'),
            onPressed: () {
              _scannerCtrl.start();
              setState(() => _showQrScanner = true);
            },
          ),
          const SizedBox(height: 12),
          _buildSectionDivider('or enter manually'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _pairCodeCtrl,
                textCapitalization: TextCapitalization.characters,
                maxLength: 6,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Fa-f0-9]')),
                ],
                style: const TextStyle(
                    color: Colors.white,
                    letterSpacing: 4,
                    fontSize: 18,
                    fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  labelText: 'Pair code (6 characters)',
                  labelStyle:
                      const TextStyle(color: Colors.white38, fontSize: 12),
                  hintText: 'A1B2C3',
                  hintStyle: const TextStyle(color: Colors.white24),
                  prefixText: 'DSGVHub_  ',
                  prefixStyle:
                      const TextStyle(color: Colors.white38, fontSize: 13),
                  counterText: '',
                  filled: true,
                  fillColor: const Color(0xFF121826),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.tealAccent)),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.tealAccent,
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _pairCodeCtrl.text.trim().length == 6
                  ? _submitPairCode
                  : null,
              child: const Text('Find',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
        ],
      ],
    );
  }

  Widget _buildQrSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 220,
            child: Stack(children: [
              MobileScanner(
                controller: _scannerCtrl,
                onDetect: _onBarcodeDetected,
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  color: Colors.black54,
                  child: const Text(
                    'Scan the DSGV provisioning QR label',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            _scannerCtrl.stop();
            setState(() => _showQrScanner = false);
          },
          child: const Text('Cancel',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buildDeviceCard() {
    final info = _deviceInfo;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Icon(info?.icon ?? Icons.power, color: Colors.tealAccent, size: 26),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info?.label ?? _deviceName ?? '',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15),
              ),
              Text(
                _deviceName ?? '',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: _resetDevice,
          child: const Text('Change',
              style: TextStyle(color: Colors.tealAccent, fontSize: 12)),
        ),
      ]),
    );
  }

  Widget _buildApConnectionCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Step 2 — Connect to device hotspot',
          style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
        ),
        const SizedBox(height: 12),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF121826),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _apConnected
                  ? const Color(0xFF00C853).withValues(alpha: 0.5)
                  : Colors.white12,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                if (_apConnected) ...[
                  const Icon(Icons.check_circle_rounded,
                      color: Color(0xFF00C853), size: 18),
                  const SizedBox(width: 8),
                  const Text('Connected to device hotspot',
                      style: TextStyle(
                          color: Color(0xFF00C853),
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                ] else ...[
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.tealAccent),
                  ),
                  const SizedBox(width: 8),
                  const Text('Waiting for connection…',
                      style: TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ]),
              const SizedBox(height: 16),
              const Text(
                'Go to your phone\'s Wi-Fi settings and connect to:',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 10),
              _buildCopyRow(
                  icon: Icons.wifi,
                  label: 'Network',
                  value: _apSsid ?? ''),
              const SizedBox(height: 8),
              _buildCopyRow(
                  icon: Icons.lock_outline,
                  label: 'Password',
                  value: _apPassword ?? ''),
              const SizedBox(height: 12),
              const Text(
                'This app will detect when you\'re connected and unlock the\n'
                'provisioning form below automatically.',
                style: TextStyle(
                    color: Colors.white38, fontSize: 11, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCopyRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E1A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(icon, color: Colors.tealAccent, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
              Text(value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 16, color: Colors.white38),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          tooltip: 'Copy',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('$label copied'),
              backgroundColor: const Color(0xFF1E2736),
              duration: const Duration(seconds: 1),
            ));
          },
        ),
      ]),
    );
  }

  Widget _buildProvisioningForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Text(
            'Step 3 — Set up your device',
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
          ),
          if (!_apConnected) ...[
            const SizedBox(width: 8),
            const Text('(connect first)',
                style: TextStyle(color: Colors.white24, fontSize: 12)),
          ],
        ]),
        const SizedBox(height: 12),
        _buildField(
          controller: _assignedNameCtrl,
          label: 'Device Name (e.g., Kitchen Switch)',
          icon: Icons.label_outline,
          enabled: _apConnected,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        _buildField(
          controller: _ssidCtrl,
          label: 'Home Wi-Fi Network (SSID)',
          icon: Icons.wifi,
          enabled: _apConnected,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        _buildField(
          controller: _wifiPassCtrl,
          label: 'Home Wi-Fi Password',
          icon: Icons.lock_outline,
          enabled: _apConnected,
          obscureText: _obscureWifiPass,
          suffix: _apConnected
              ? IconButton(
                  icon: Icon(
                      _obscureWifiPass
                          ? Icons.visibility_off
                          : Icons.visibility,
                      color: Colors.white38,
                      size: 20),
                  onPressed: () =>
                      setState(() => _obscureWifiPass = !_obscureWifiPass),
                )
              : null,
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.tealAccent,
            foregroundColor: Colors.black,
            disabledBackgroundColor:
                Colors.tealAccent.withValues(alpha: 0.25),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: (_isSending ||
                  !_apConnected ||
                  _ssidCtrl.text.trim().isEmpty ||
                  _assignedNameCtrl.text.trim().isEmpty)
              ? null
              : _sendCredentials,
          icon: _isSending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black))
              : const Icon(Icons.send_rounded, size: 18),
          label: Text(_isSending ? 'Sending…' : 'Send Credentials'),
        ),
      ],
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool enabled = true,
    bool obscureText = false,
    Widget? suffix,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      enabled: enabled,
      style: TextStyle(
          color: enabled ? Colors.white : Colors.white24),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
            color: enabled ? Colors.white38 : Colors.white12),
        prefixIcon:
            Icon(icon, color: enabled ? Colors.tealAccent : Colors.white12),
        suffixIcon: suffix,
        filled: true,
        fillColor: enabled
            ? const Color(0xFF121826)
            : const Color(0xFF0D1220),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.tealAccent)),
        disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
      ),
    );
  }

  Widget _buildStatusBanner() {
    if (_isSending) {
      return Text(
        _statusMessage!,
        textAlign: TextAlign.center,
        style:
            const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
      );
    }
    if (_isSuccess) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF071A0F),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: const Color(0xFF00C853).withValues(alpha: 0.45)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.check_circle_rounded,
              color: Color(0xFF00C853), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Provisioned successfully',
                      style: TextStyle(
                          color: Color(0xFF00C853),
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(_statusMessage!,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12, height: 1.5)),
                ]),
          ),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A0707),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.error_rounded, color: Colors.redAccent, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Error',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Text(_statusMessage!,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12, height: 1.5)),
              ]),
        ),
      ]),
    );
  }

  Widget _buildSectionDivider(String label) {
    return Row(children: [
      const Expanded(child: Divider(color: Colors.white12)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text(label,
            style: const TextStyle(color: Colors.white24, fontSize: 12)),
      ),
      const Expanded(child: Divider(color: Colors.white12)),
    ]);
  }

  Widget _buildFooter() {
    return const Text(
      'Your device creates a secured hotspot that only this app can access.\n'
      'Credentials are sent directly to the device and never uploaded to any server.',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.white24, fontSize: 11, height: 1.6),
    );
  }
}
