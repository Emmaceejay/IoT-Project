import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../domain/services/ble_provisioning_service.dart';
import '../../domain/services/device_manager.dart';

// ── Device type presets ───────────────────────────────────────────────────────
// Each preset maps a human-readable label to the capability list that gets
// sent to the device over BLE and stored in the device's NVS flash.
// The capabilities list is what drives both the local UI and the C2C voice
// trait mapping in the cloud (Google Home / Alexa / SmartThings).

class _DevicePreset {
  final String label;
  final String deviceType;
  final List<String> capabilities;
  final int relayCount;

  const _DevicePreset({
    required this.label,
    required this.deviceType,
    required this.capabilities,
    required this.relayCount,
  });
}

const _kDevicePresets = [
  // Switches — one or more independent relay outputs
  _DevicePreset(label: '1-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay'],                                                   relayCount: 1),
  _DevicePreset(label: '2-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2'],                                        relayCount: 2),
  _DevicePreset(label: '3-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2', 'relay_3'],                             relayCount: 3),
  _DevicePreset(label: '4-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2', 'relay_3', 'relay_4'],                  relayCount: 4),

  // Lighting — relay + LEDC PWM channels
  _DevicePreset(label: 'Dimmer',         deviceType: 'Dimmer',     capabilities: ['relay', 'brightness'],                                     relayCount: 1),
  _DevicePreset(label: 'Color Temp',     deviceType: 'Light',      capabilities: ['relay', 'brightness', 'color_temp'],                       relayCount: 1),
  _DevicePreset(label: 'RGB Light',      deviceType: 'Light',      capabilities: ['relay', 'brightness', 'rgb'],                              relayCount: 1),

  // Sensors — read-only, no relay outputs
  _DevicePreset(label: 'Temp Sensor',    deviceType: 'Sensor',     capabilities: ['temperature', 'humidity'],                                 relayCount: 0),
  _DevicePreset(label: 'Motion Sensor',  deviceType: 'Sensor',     capabilities: ['motion'],                                                  relayCount: 0),
  _DevicePreset(label: 'Contact Sensor', deviceType: 'Sensor',     capabilities: ['contact'],                                                 relayCount: 0),

  // Climate
  _DevicePreset(label: 'Thermostat',     deviceType: 'Thermostat', capabilities: ['temperature', 'hvac_mode'],                                relayCount: 1),
];

// ── QR code parsing ───────────────────────────────────────────────────────────
// DSGV provisioning QR codes always use the dsgv:// scheme:
//   dsgv://provision?name=DSGVHub_A1B2C3
// The "name" parameter is the BLE device name the app searches for.

class _ParsedQr {
  final String raw;

  /// The BLE device name extracted from the QR code's "name=" parameter,
  /// e.g. "DSGVHub_A1B2C3". The BLE provisioning service scans for this name.
  final String dsgvDeviceName;

  const _ParsedQr(this.raw, this.dsgvDeviceName);

  /// Tries to parse [raw] as a DSGV provisioning QR code.
  /// Returns null for any other QR code type.
  static _ParsedQr? tryParse(String raw) {
    if (!raw.startsWith('dsgv://provision')) return null;
    final uri  = Uri.tryParse(raw);
    final name = uri?.queryParameters['name'];
    if (name == null || name.isEmpty) return null;
    return _ParsedQr(raw, name);
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

// Tracks the final outcome of a provisioning attempt so the UI can switch from
// the live-progress form to a dedicated result card.
enum _ProvisionResult { none, success, failed }

class DevicePairingScreen extends ConsumerStatefulWidget {
  const DevicePairingScreen({super.key});

  @override
  ConsumerState<DevicePairingScreen> createState() =>
      _DevicePairingScreenState();
}

class _DevicePairingScreenState extends ConsumerState<DevicePairingScreen> {
  // ── Controllers ───────────────────────────────────────────────────────────
  final _nameCtrl     = TextEditingController();
  final _ssidCtrl     = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _scannerCtrl  = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  // ── State ─────────────────────────────────────────────────────────────────
  _ParsedQr?      _parsedQr;
  bool            _scannerActive    = false;
  bool            _obscurePassword  = true;
  _DevicePreset   _selectedPreset   = _kDevicePresets.first;
  bool            _inProgress       = false;
  String?         _statusMessage;
  bool            _isSuccess        = false;
  ProvisioningStep? _provStep;
  // Set when the provisioning stream terminates; drives the result card.
  _ProvisionResult _result          = _ProvisionResult.none;
  String           _resultMessage   = '';

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    _scannerCtrl.dispose();
    super.dispose();
  }

  // ── Scanner callbacks ─────────────────────────────────────────────────────

  void _onBarcodeDetected(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    final parsed = _ParsedQr.tryParse(raw);
    if (parsed == null) {
      setState(() {
        _statusMessage =
            'Unrecognised QR code. Scan a DSGV provisioning QR (dsgv://…).';
      });
      return;
    }

    _scannerCtrl.stop();
    setState(() {
      _parsedQr       = parsed;
      _scannerActive  = false;
      _statusMessage  =
          'Device found: ${parsed.dsgvDeviceName}.\n'
          'Enter a name and your Wi-Fi credentials, then tap Provision.';
    });
  }

  void _resetScanner() {
    _scannerCtrl.stop();
    setState(() {
      _parsedQr       = null;
      _scannerActive  = false;
      _statusMessage  = null;
      _isSuccess      = false;
      _inProgress     = false;
      _provStep       = null;
      _selectedPreset = _kDevicePresets.first;
      _result         = _ProvisionResult.none;
      _resultMessage  = '';
    });
  }

  // ── BLE provisioning ──────────────────────────────────────────────────────

  Future<void> _startProvisioning() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Please enter a device name.');
      return;
    }
    if (_parsedQr == null) {
      setState(() => _statusMessage = 'Please scan the device QR code first.');
      return;
    }
    if (_ssidCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Please enter your Wi-Fi network name (SSID).');
      return;
    }
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _statusMessage = 'Please enter your Wi-Fi password.');
      return;
    }

    setState(() {
      _inProgress    = true;
      _statusMessage = null;
      _isSuccess     = false;
    });

    // BleProvisioningService.provision() is a stream that yields progress
    // steps as it connects to the device over Bluetooth, sends Wi-Fi
    // credentials, and waits for the device to reboot and confirm.
    // Each ProvisioningStatus carries a step enum and optional message string.
    final stream = BleProvisioningService.provision(
      deviceName:   _parsedQr!.dsgvDeviceName,
      ssid:         _ssidCtrl.text.trim(),
      password:     _passwordCtrl.text,
      deviceType:   _selectedPreset.deviceType,
      capabilities: _selectedPreset.capabilities,
      relayCount:   _selectedPreset.relayCount,
    );

    await for (final status in stream) {
      if (!mounted) return;
      setState(() {
        _provStep      = status.step;
        _statusMessage = status.message ?? _stepLabel(status.step);
        _isSuccess     = status.step == ProvisioningStep.success;
        if (status.isTerminal) _inProgress = false;
      });

      if (status.step == ProvisioningStep.success) {
        if (status.authToken != null && status.provisionedDeviceId != null) {
          final manager = ref.read(deviceManagerProvider.notifier);

          // Cache the auth token locally so that when the device's MQTT
          // announce arrives (a few seconds after reboot) the DeviceManager
          // can match the announce to this session and attach the token.
          manager.setPendingToken(
            status.provisionedDeviceId!,
            status.authToken!,
          );

          // Fire-and-forget Firebase registration.  The device still works on
          // the factory broker config even if this call fails, so we log the
          // error but do not surface it to the user.
          manager.registerDevice(
            status.provisionedDeviceId!,
            status.authToken!,
          ).catchError((Object e) {
            debugPrint('[Pairing] Firebase registration failed (non-fatal): $e');
          });
        }

        // Switch to the success result card instead of auto-navigating away —
        // this lets the user clearly see the outcome and choose what to do next.
        if (mounted) {
          setState(() {
            _result        = _ProvisionResult.success;
            _resultMessage = status.message ?? 'Device provisioned successfully!';
          });
        }
        return;
      }

      if (status.step == ProvisioningStep.failed) {
        if (mounted) {
          setState(() {
            _result        = _ProvisionResult.failed;
            _resultMessage = status.message ?? 'Provisioning failed. Please try again.';
          });
        }
        return;
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Maps the current [ProvisioningStep] to a display string shown in the UI.
  String _stepLabel(ProvisioningStep step) => switch (step) {
        ProvisioningStep.requestingPermissions => 'Requesting Bluetooth permissions…',
        ProvisioningStep.scanningForDevice     => 'Scanning for device via BLE…',
        ProvisioningStep.connecting            => 'Connecting to device…',
        ProvisioningStep.discoveringServices   => 'Discovering BLE services…',
        ProvisioningStep.sendingCredentials    => 'Sending Wi-Fi credentials…',
        ProvisioningStep.waitingForDevice      => 'Waiting for device to connect…',
        ProvisioningStep.success               => 'Provisioned successfully!',
        ProvisioningStep.failed                => 'Provisioning failed.',
      };

  /// Whether the provision button should be enabled.
  bool get _canProvision {
    if (_inProgress || _parsedQr == null)      return false;
    if (_result != _ProvisionResult.none)       return false;
    if (_nameCtrl.text.trim().isEmpty)         return false;
    if (_ssidCtrl.text.trim().isEmpty)         return false;
    return true;
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
          'Pair New Device',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: _result != _ProvisionResult.none
            ? _buildResultCard()
            : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildScannerSection(),
            const SizedBox(height: 28),

            // Device name field
            _buildTextField(
              controller: _nameCtrl,
              label: 'Device Name (e.g., Kitchen Switch)',
              icon: Icons.label_outline,
              onChanged: (_) => setState(() {}),
            ),

            // Device type and Wi-Fi fields — only shown after a valid QR scan
            if (_parsedQr != null) ...[
              const SizedBox(height: 16),
              _buildPresetDropdown(),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _ssidCtrl,
                label: 'Wi-Fi Network Name (SSID)',
                icon: Icons.wifi,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              _buildTextField(
                controller: _passwordCtrl,
                label: 'Wi-Fi Password',
                icon: Icons.lock_outline,
                obscureText: _obscurePassword,
                suffix: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility_off : Icons.visibility,
                    color: Colors.white38,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Provisioning step progress bar
            if (_inProgress && _provStep != null) ...[
              _buildProvisioningProgress(_provStep!),
              const SizedBox(height: 12),
            ],

            // Status message (error, progress, or success)
            if (_statusMessage != null) ...[
              Text(
                _statusMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _isSuccess
                      ? const Color(0xFF00E5FF)
                      : _inProgress
                          ? Colors.white70
                          : Colors.redAccent,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Provision button
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
                disabledBackgroundColor:
                    const Color(0xFF00E5FF).withValues(alpha: 0.4),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _canProvision ? _startProvisioning : null,
              icon: _inProgress
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.bluetooth_searching),
              label: Text(
                _inProgress
                    ? 'Provisioning…'
                    : _parsedQr == null
                        ? 'Scan QR Code First'
                        : 'Provision Device',
              ),
            ),

            const SizedBox(height: 32),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  // ── Widget helpers ─────────────────────────────────────────────────────────

  /// Full-screen result card shown when provisioning completes (success or
  /// failure).  Replaces the form entirely so the outcome is unmistakable.
  Widget _buildResultCard() {
    final isSuccess = _result == _ProvisionResult.success;

    // Icon + colours differ between success and failure
    final iconData  = isSuccess ? Icons.check_circle_rounded : Icons.cancel_rounded;
    final iconColor = isSuccess ? const Color(0xFF00E695) : const Color(0xFFFF5252);
    final cardColor = isSuccess
        ? const Color(0xFF00E695).withValues(alpha: 0.08)
        : const Color(0xFFFF5252).withValues(alpha: 0.08);
    final borderColor = isSuccess
        ? const Color(0xFF00E695).withValues(alpha: 0.4)
        : const Color(0xFFFF5252).withValues(alpha: 0.4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 40),

        // ── Outcome card ────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: cardColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              // Large outcome icon
              Icon(iconData, size: 72, color: iconColor),
              const SizedBox(height: 20),

              // Headline
              Text(
                isSuccess ? 'Device Added!' : 'Provisioning Failed',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: iconColor,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),

              // Descriptive message from the provisioning stream
              Text(
                _resultMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.6,
                ),
              ),

              // Extra hint for failure cases
              if (!isSuccess) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.tips_and_updates_outlined,
                          size: 16, color: Colors.white38),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Make sure the device is powered on, in range, '
                          'and has not already been provisioned.',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 12, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 28),

        // ── Action buttons ──────────────────────────────────────────────────
        if (isSuccess) ...[
          // Primary: go back to the dashboard
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E695),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.dashboard_rounded),
            label: const Text('Go to Dashboard',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),

          // Secondary: stay on screen and provision another device
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _resetScanner,
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: const Text('Provision Another Device'),
          ),
        ] else ...[
          // Failure: retry from the beginning
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _resetScanner,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try Again',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),

          // Let the user also bail out entirely
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white54,
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('Back to Dashboard'),
          ),
        ],

        const SizedBox(height: 32),
        _buildFooter(),
      ],
    );
  }

  Widget _buildScannerSection() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 220,
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          border: Border.all(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: _scannerActive
            ? Stack(children: [
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
                      'Scan DSGV provisioning QR code (dsgv://…)',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ),
              ])
            : _parsedQr != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.bluetooth_searching,
                          size: 48, color: Color(0xFF00E5FF)),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          _parsedQr!.dsgvDeviceName,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _resetScanner,
                        icon: const Icon(Icons.refresh,
                            color: Color(0xFF00E5FF), size: 16),
                        label: const Text('Rescan',
                            style: TextStyle(color: Color(0xFF00E5FF))),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.qr_code_scanner,
                          size: 52, color: Color(0xFF00E5FF)),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E2A3A),
                          foregroundColor: const Color(0xFF00E5FF),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          _scannerCtrl.start();
                          setState(() => _scannerActive = true);
                        },
                        icon: const Icon(Icons.camera_alt, size: 18),
                        label: const Text('Scan QR'),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    Widget? suffix,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      style: const TextStyle(color: Colors.white),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white38),
        prefixIcon: Icon(icon, color: const Color(0xFF00E5FF)),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF121826),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00E5FF)),
        ),
      ),
    );
  }

  Widget _buildPresetDropdown() {
    return DropdownButtonFormField<_DevicePreset>(
      initialValue: _selectedPreset,
      dropdownColor: const Color(0xFF121826),
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: 'Device Type',
        labelStyle: const TextStyle(color: Colors.white38),
        prefixIcon:
            const Icon(Icons.devices_other, color: Color(0xFF00E5FF)),
        filled: true,
        fillColor: const Color(0xFF121826),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00E5FF)),
        ),
      ),
      items: _kDevicePresets
          .map((p) =>
              DropdownMenuItem(value: p, child: Text(p.label)))
          .toList(),
      onChanged: _inProgress
          ? null
          : (p) =>
              setState(() => _selectedPreset = p ?? _selectedPreset),
    );
  }

  Widget _buildProvisioningProgress(ProvisioningStep step) {
    // The steps are ordered here to match the actual provisioning sequence.
    // The progress bar advances one notch per step.
    const steps = [
      ProvisioningStep.requestingPermissions,
      ProvisioningStep.scanningForDevice,
      ProvisioningStep.connecting,
      ProvisioningStep.discoveringServices,
      ProvisioningStep.sendingCredentials,
      ProvisioningStep.waitingForDevice,
    ];
    final currentIndex = steps.indexOf(step);
    return LinearProgressIndicator(
      value: currentIndex < 0
          ? null // indeterminate while calculating
          : (currentIndex + 1) / steps.length,
      backgroundColor: const Color(0xFF1E2736),
      color: const Color(0xFF00E5FF),
      borderRadius: BorderRadius.circular(4),
      minHeight: 4,
    );
  }

  Widget _buildFooter() {
    return const Text(
      'Wi-Fi credentials are sent directly to your device\n'
      'over an encrypted BLE channel. They are never uploaded\n'
      'to any server.',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.white24, fontSize: 11, height: 1.6),
    );
  }
}
