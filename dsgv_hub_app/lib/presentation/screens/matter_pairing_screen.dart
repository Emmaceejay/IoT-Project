import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../domain/services/ble_provisioning_service.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/matter_commissioning_service.dart';

// ── Device type presets ───────────────────────────────────────────────────────

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
  _DevicePreset(label: '1-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay'],                                                   relayCount: 1),
  _DevicePreset(label: '2-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2'],                                        relayCount: 2),
  _DevicePreset(label: '3-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2', 'relay_3'],                             relayCount: 3),
  _DevicePreset(label: '4-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2', 'relay_3', 'relay_4'],                  relayCount: 4),
  _DevicePreset(label: 'Dimmer',         deviceType: 'Dimmer',     capabilities: ['relay', 'brightness'],                                     relayCount: 1),
  _DevicePreset(label: 'Color Temp',     deviceType: 'Light',      capabilities: ['relay', 'brightness', 'color_temp'],                       relayCount: 1),
  _DevicePreset(label: 'RGB Light',      deviceType: 'Light',      capabilities: ['relay', 'brightness', 'rgb'],                              relayCount: 1),
  _DevicePreset(label: 'Temp Sensor',    deviceType: 'Sensor',     capabilities: ['temperature', 'humidity'],                                 relayCount: 0),
  _DevicePreset(label: 'Motion Sensor',  deviceType: 'Sensor',     capabilities: ['motion'],                                                  relayCount: 0),
  _DevicePreset(label: 'Contact Sensor', deviceType: 'Sensor',     capabilities: ['contact'],                                                 relayCount: 0),
  _DevicePreset(label: 'Thermostat',     deviceType: 'Thermostat', capabilities: ['temperature', 'hvac_mode'],                                relayCount: 1),
];

// ── QR code type ──────────────────────────────────────────────────────────────

enum _QrType { dsgvProvision, matter }

class _ParsedQr {
  final _QrType type;
  final String raw;

  /// For dsgvProvision: the BLE device name (e.g. "DSGVHub_A1B2C3")
  final String? dsgvDeviceName;

  const _ParsedQr.dsgv(this.raw, this.dsgvDeviceName)
      : type = _QrType.dsgvProvision;

  const _ParsedQr.matter(this.raw)
      : type = _QrType.matter,
        dsgvDeviceName = null;

  /// Parses a raw QR string and returns a typed result, or null if unknown.
  static _ParsedQr? tryParse(String raw) {
    // dsgv://provision?name=DSGVHub_XXXXXX
    if (raw.startsWith('dsgv://provision')) {
      final uri = Uri.tryParse(raw);
      final name = uri?.queryParameters['name'];
      if (name != null && name.isNotEmpty) {
        return _ParsedQr.dsgv(raw, name);
      }
      return null;
    }
    // MT:XXXXXX — Matter setup payload
    if (raw.startsWith('MT:')) {
      return _ParsedQr.matter(raw);
    }
    return null;
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class MatterPairingScreen extends ConsumerStatefulWidget {
  const MatterPairingScreen({super.key});

  @override
  ConsumerState<MatterPairingScreen> createState() =>
      _MatterPairingScreenState();
}

class _MatterPairingScreenState extends ConsumerState<MatterPairingScreen> {
  // Controllers
  final _nameCtrl     = TextEditingController();
  final _ssidCtrl     = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _scannerCtrl  = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  // State
  _ParsedQr? _parsedQr;
  bool _scannerActive = true;
  bool _obscurePassword = true;
  _DevicePreset _selectedPreset = _kDevicePresets.first;

  // Provisioning/commissioning progress
  bool _inProgress = false;
  String? _statusMessage;
  bool _isSuccess = false;
  ProvisioningStep? _provStep;

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
      // Scanned something unrecognised — show a brief hint
      setState(() {
        _statusMessage =
            'Unrecognised QR code. Scan a DSGV provisioning or Matter QR code.';
      });
      return;
    }

    _scannerCtrl.stop();
    setState(() {
      _parsedQr = parsed;
      _scannerActive = false;
      _statusMessage = parsed.type == _QrType.dsgvProvision
          ? 'DSGV device found: ${parsed.dsgvDeviceName}.\n'
            'Enter a name and your Wi-Fi credentials, then tap Provision.'
          : 'Matter QR captured. Enter a name and tap Commission.';
    });
  }

  void _resetScanner() {
    setState(() {
      _parsedQr = null;
      _scannerActive = true;
      _statusMessage = null;
      _isSuccess = false;
      _inProgress = false;
      _provStep = null;
      _selectedPreset = _kDevicePresets.first;
    });
    _scannerCtrl.start();
  }

  // ── Action handlers ───────────────────────────────────────────────────────

  Future<void> _startAction() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Please enter a device name.');
      return;
    }
    if (_parsedQr == null) {
      setState(() => _statusMessage = 'Please scan the device QR code first.');
      return;
    }

    if (_parsedQr!.type == _QrType.dsgvProvision) {
      await _runBleProvisioning();
    } else {
      await _runMatterCommissioning();
    }
  }

  Future<void> _runBleProvisioning() async {
    if (_ssidCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Please enter your Wi-Fi network name (SSID).');
      return;
    }
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _statusMessage = 'Please enter your Wi-Fi password.');
      return;
    }

    setState(() {
      _inProgress = true;
      _statusMessage = null;
      _isSuccess = false;
    });

    final service = ref.read(matterCommissioningProvider);
    final stream = service.provisionViaBle(
      deviceName: _parsedQr!.dsgvDeviceName!,
      ssid: _ssidCtrl.text.trim(),
      password: _passwordCtrl.text,
      assignedName: _nameCtrl.text.trim(),
      deviceType:   _selectedPreset.deviceType,
      capabilities: _selectedPreset.capabilities,
      relayCount:   _selectedPreset.relayCount,
    );

    await for (final status in stream) {
      if (!mounted) return;
      setState(() {
        _provStep = status.step;
        _statusMessage = status.message ?? _stepLabel(status.step);
        _isSuccess = status.step == ProvisioningStep.success;
        if (status.isTerminal) _inProgress = false;
      });
      if (status.step == ProvisioningStep.success) {
        // Store the auth token so the app can send authenticated broker-change
        // commands to this device later without needing BLE again.
        if (status.authToken != null && status.provisionedDeviceId != null) {
          ref.read(deviceManagerProvider.notifier).setPendingToken(
            status.provisionedDeviceId!,
            status.authToken!,
          );
        }
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) Navigator.of(context).pop();
        return;
      }
    }
  }

  Future<void> _runMatterCommissioning() async {
    setState(() {
      _inProgress = true;
      _statusMessage = 'Commissioning Matter device…';
      _isSuccess = false;
    });

    final service = ref.read(matterCommissioningProvider);
    final result = await service.commissionDevice(
      qrCodeString: _parsedQr!.raw,
      assignedName: _nameCtrl.text.trim(),
    );

    if (!mounted) return;
    setState(() {
      _inProgress = false;
      _statusMessage = result.message;
      _isSuccess = result.success;
    });

    if (result.success) {
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.of(context).pop();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

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

  bool get _canAct {
    if (_inProgress || _parsedQr == null) return false;
    if (_nameCtrl.text.trim().isEmpty) return false;
    // For BLE provisioning the SSID is also mandatory
    if (_parsedQr!.type == _QrType.dsgvProvision &&
        _ssidCtrl.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  String get _actionLabel {
    if (_parsedQr == null) return 'Scan QR Code First';
    if (_inProgress) {
      return _parsedQr!.type == _QrType.dsgvProvision
          ? 'Provisioning…'
          : 'Commissioning…';
    }
    return _parsedQr!.type == _QrType.dsgvProvision
        ? 'Provision Device'
        : 'Commission Device';
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── QR Scanner / Preview ─────────────────────────────────────
            _buildScannerSection(),

            const SizedBox(height: 28),

            // ── Device Name ───────────────────────────────────────────────
            _buildTextField(
              controller: _nameCtrl,
              label: 'Device Name (e.g., Kitchen Switch)',
              icon: Icons.label_outline,
              onChanged: (_) => setState(() {}),
            ),

            // ── Device type preset (DSGV BLE provisioning only) ─────────
            if (_parsedQr?.type == _QrType.dsgvProvision) ...[
              const SizedBox(height: 16),
              _buildPresetDropdown(),
            ],

            // ── Wi-Fi credentials (DSGV BLE provisioning only) ───────────
            if (_parsedQr?.type == _QrType.dsgvProvision) ...[
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

            // ── Progress indicator (BLE provisioning) ─────────────────────
            if (_inProgress &&
                _parsedQr?.type == _QrType.dsgvProvision &&
                _provStep != null) ...[
              _buildProvisioningProgress(_provStep!),
              const SizedBox(height: 12),
            ],

            // ── Status message ────────────────────────────────────────────
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

            // ── Action button ─────────────────────────────────────────────
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
              onPressed: _canAct ? _startAction : null,
              icon: _inProgress
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : Icon(_parsedQr?.type == _QrType.dsgvProvision
                      ? Icons.bluetooth_searching
                      : Icons.devices),
              label: Text(_actionLabel),
            ),

            const SizedBox(height: 32),

            // ── Info footer ───────────────────────────────────────────────
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  // ── Widget helpers ─────────────────────────────────────────────────────────

  Widget _buildScannerSection() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 220,
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          border: Border.all(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.3),
          ),
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
                      'Scan a DSGV provisioning QR (DSGV://…) or Matter QR (MT:…)',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ),
              ])
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _parsedQr?.type == _QrType.dsgvProvision
                        ? Icons.bluetooth_searching
                        : Icons.check_circle,
                    size: 48,
                    color: const Color(0xFF00E5FF),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _parsedQr?.type == _QrType.dsgvProvision
                          ? 'DSGV: ${_parsedQr!.dsgvDeviceName}'
                          : 'Matter: ${_parsedQr?.raw}',
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
        prefixIcon: const Icon(Icons.devices_other, color: Color(0xFF00E5FF)),
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
          .map((p) => DropdownMenuItem(
                value: p,
                child: Text(p.label),
              ))
          .toList(),
      onChanged: _inProgress
          ? null
          : (p) => setState(() => _selectedPreset = p ?? _selectedPreset),
    );
  }

  Widget _buildProvisioningProgress(ProvisioningStep step) {
    const steps = [
      ProvisioningStep.requestingPermissions,
      ProvisioningStep.scanningForDevice,
      ProvisioningStep.connecting,
      ProvisioningStep.discoveringServices,
      ProvisioningStep.sendingCredentials,
      ProvisioningStep.waitingForDevice,
    ];
    final currentIndex = steps.indexOf(step);
    return Column(
      children: [
        LinearProgressIndicator(
          value: currentIndex < 0
              ? null
              : (currentIndex + 1) / steps.length,
          backgroundColor: const Color(0xFF1E2736),
          color: const Color(0xFF00E5FF),
          borderRadius: BorderRadius.circular(4),
          minHeight: 4,
        ),
      ],
    );
  }

  Widget _buildFooter() {
    final isDSGV = _parsedQr?.type == _QrType.dsgvProvision;
    return Text(
      isDSGV
          ? 'Wi-Fi credentials are sent directly to your device\n'
            'over an encrypted BLE channel. They are never uploaded\n'
            'to any server.'
          : 'Matter pairing uses the OS-native BLE commissioning\n'
            'stack to securely onboard your device.',
      textAlign: TextAlign.center,
      style: const TextStyle(color: Colors.white24, fontSize: 11, height: 1.6),
    );
  }
}
