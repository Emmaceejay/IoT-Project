import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../domain/services/ble_provisioning_service.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/device_commissioning_service.dart';

// ── QR code type ──────────────────────────────────────────────────────────────

enum _QrType { dsgvProvision, shortCode }

class _ParsedQr {
  final _QrType type;
  final String raw;

  /// For dsgvProvision: the BLE device name (e.g. "DSGVHub_A1B2C3")
  final String? dsgvDeviceName;

  const _ParsedQr.dsgv(this.raw, this.dsgvDeviceName)
      : type = _QrType.dsgvProvision;

  const _ParsedQr.shortCode(this.raw)
      : type = _QrType.shortCode,
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
    // MT:XXXXXX — setup payload short code
    if (raw.startsWith('MT:')) {
      return _ParsedQr.shortCode(raw);
    }
    return null;
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class DevicePairingScreen extends ConsumerStatefulWidget {
  /// When true, the camera opens immediately on load.
  /// When false (default), the scanner shows an idle placeholder and the user
  /// taps to activate it.  Pass [openScanner: false] when launching from the
  /// "Enter pair code" flow so the manual entry form is shown first.
  final bool openScanner;

  const DevicePairingScreen({super.key, this.openScanner = false});

  @override
  ConsumerState<DevicePairingScreen> createState() =>
      _DevicePairingScreenState();
}

class _DevicePairingScreenState extends ConsumerState<DevicePairingScreen> {
  // Controllers
  final _nameCtrl     = TextEditingController();
  final _ssidCtrl     = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _scannerCtrl  = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  // State — initialised in initState via widget.openScanner
  late bool _scannerActive;
  bool _obscurePassword = true;

  // Provisioning/commissioning progress
  bool _inProgress = false;
  String? _statusMessage;
  bool _isSuccess = false;
  ProvisioningStep? _provStep;

  // Pre-provisioning device info fetched automatically after QR scan.
  _ParsedQr? _parsedQr;
  ProvisioningDeviceInfo? _deviceInfo;
  bool _isLoadingDeviceInfo = false;
  bool _manualSsidEntry = false;

  // ── Option 1: manual pair-code entry ─────────────────────────────────────
  final _pairCodeCtrl = TextEditingController();
  late bool _showManualEntry;

  // ── Option 2: BLE device picker ──────────────────────────────────────────
  bool _isScanning = false;
  List<BluetoothDevice> _nearbyDevices = [];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _scannerActive    = widget.openScanner;
    _showManualEntry  = !widget.openScanner;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    _pairCodeCtrl.dispose();
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
            'Unrecognised QR code. Scan a DSGV provisioning or setup QR code.';
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
          : 'QR captured. Enter a name and tap Commission.';
    });

    if (parsed.type == _QrType.dsgvProvision &&
        parsed.dsgvDeviceName != null) {
      _loadProvisioningData(parsed.dsgvDeviceName!);
    }
  }

  void _resetScanner() {
    setState(() {
      _parsedQr = null;
      _scannerActive = true;
      _statusMessage = null;
      _isSuccess = false;
      _inProgress = false;
      _provStep = null;
      _deviceInfo = null;
      _isLoadingDeviceInfo = false;
      _manualSsidEntry = false;
      _ssidCtrl.clear();
    });
    _scannerCtrl.start();
  }

  Future<void> _loadProvisioningData(String deviceName) async {
    setState(() => _isLoadingDeviceInfo = true);
    final info = await BleProvisioningService.fetchProvisioningData(deviceName);
    if (!mounted) return;
    setState(() {
      _deviceInfo = info;
      _isLoadingDeviceInfo = false;
      if (info.networks.length == 1 && _ssidCtrl.text.isEmpty) {
        _ssidCtrl.text = info.networks.first.ssid;
      }
    });
  }

  // ── Option 1: manual pair-code entry ─────────────────────────────────────

  void _submitManualCode() {
    final code = _pairCodeCtrl.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(() =>
          _statusMessage = 'Enter the 6-character pair code from the device label.');
      return;
    }
    final deviceName = 'DSGVHub_$code';
    _scannerCtrl.stop();
    setState(() {
      _parsedQr = _ParsedQr.dsgv('manual:$deviceName', deviceName);
      _scannerActive = false;
      _showManualEntry = false;
      _nearbyDevices = [];
      _statusMessage = 'Device code accepted: $deviceName\n'
          'Enter a name and your Wi-Fi credentials, then tap Provision.';
    });
    _loadProvisioningData(deviceName);
  }

  // ── Option 2: BLE device picker ──────────────────────────────────────────

  Future<void> _scanNearbyDevices() async {
    setState(() {
      _isScanning = true;
      _nearbyDevices = [];
      _statusMessage = null;
    });
    final found = await BleProvisioningService.discoverNearbyDevices();
    if (!mounted) return;
    if (found.isEmpty) {
      setState(() {
        _isScanning = false;
        _statusMessage = 'No DSGV devices found nearby. Make sure the device is '
            'powered on and in provisioning mode.';
      });
      return;
    }
    setState(() {
      _isScanning = false;
      _nearbyDevices = found;
    });
  }

  void _selectNearbyDevice(BluetoothDevice device) {
    final deviceName = device.platformName;
    setState(() {
      _parsedQr = _ParsedQr.dsgv('picker:$deviceName', deviceName);
      _scannerActive = false;
      _nearbyDevices = [];
      _showManualEntry = false;
      _statusMessage = 'Selected: $deviceName\n'
          'Enter a name and your Wi-Fi credentials, then tap Provision.';
    });
    _loadProvisioningData(deviceName);
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
      await _runCommissioning();
    }
  }

  Future<void> _runBleProvisioning() async {
    if (_ssidCtrl.text.trim().isEmpty) {
      setState(
          () => _statusMessage = 'Please enter your Wi-Fi network name (SSID).');
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

    final service = ref.read(deviceCommissioningProvider);
    final stream = service.provisionViaBle(
      deviceName:   _parsedQr!.dsgvDeviceName!,
      ssid:         _ssidCtrl.text.trim(),
      password:     _passwordCtrl.text,
      assignedName: _nameCtrl.text.trim(),
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
        if (status.authToken != null && status.provisionedDeviceId != null) {
          final manager = ref.read(deviceManagerProvider.notifier);
          manager.setPendingToken(
            status.provisionedDeviceId!,
            status.authToken!,
          );
          if (_parsedQr?.dsgvDeviceName != null) {
            manager.setPendingBleName(
              status.provisionedDeviceId!,
              _parsedQr!.dsgvDeviceName!,
            );
          }
          manager.registerDevice(
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

  Future<void> _runCommissioning() async {
    setState(() {
      _inProgress = true;
      _statusMessage = 'Commissioning device…';
      _isSuccess = false;
    });

    final service = ref.read(deviceCommissioningProvider);
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
            // ── QR Scanner / Preview / Idle ──────────────────────────────
            _buildScannerSection(),

            // ── Fallback options (damaged QR / no QR) ───────────────────
            if (_parsedQr == null) ...[
              const SizedBox(height: 16),
              _buildFallbackOptions(),
            ],

            const SizedBox(height: 28),

            // ── Device Name ──────────────────────────────────────────────
            _buildTextField(
              controller: _nameCtrl,
              label: 'Device Name (e.g., Kitchen Switch)',
              icon: Icons.label_outline,
              onChanged: (_) => setState(() {}),
            ),

            // ── Auto-detected device type (DSGV BLE provisioning only) ──
            if (_parsedQr?.type == _QrType.dsgvProvision) ...[
              const SizedBox(height: 16),
              _buildDeviceInfoCard(),
            ],

            // ── Wi-Fi credentials (DSGV BLE provisioning only) ──────────
            if (_parsedQr?.type == _QrType.dsgvProvision) ...[
              const SizedBox(height: 16),
              _buildSsidSection(),
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

            // ── Progress indicator ────────────────────────────────────────
            if (_inProgress &&
                _parsedQr?.type == _QrType.dsgvProvision &&
                _provStep != null) ...[
              _buildProvisioningProgress(_provStep!),
              const SizedBox(height: 12),
            ],

            // ── Status message ────────────────────────────────────────────
            if (_statusMessage != null) ...[
              _buildStatusBanner(),
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
            // ── Camera live ──────────────────────────────────────────────
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
                      'Scan a DSGV provisioning QR or setup short-code',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ),
              ])
            : _parsedQr != null
                // ── QR captured ──────────────────────────────────────────
                ? Column(
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
                              : 'Code: ${_parsedQr?.raw}',
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
                // ── Idle — user hasn't activated camera yet ───────────────
                : _buildScanIdlePlaceholder(),
      ),
    );
  }

  Widget _buildScanIdlePlaceholder() {
    return InkWell(
      onTap: () {
        _scannerCtrl.start();
        setState(() => _scannerActive = true);
      },
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.qr_code_scanner, size: 52, color: Color(0xFF00E5FF)),
          SizedBox(height: 12),
          Text(
            'Tap to open camera',
            style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500),
          ),
          SizedBox(height: 4),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Scan the QR label on the device',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
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

  Widget _buildDeviceInfoCard() {
    if (_isLoadingDeviceInfo) {
      return _buildDisabledField(
        icon: Icons.devices_other,
        label: 'Reading device identity…',
        trailing: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF00E5FF)),
        ),
      );
    }

    final info = _deviceInfo;
    if (info == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF00E5FF).withValues(alpha: 0.25),
        ),
      ),
      child: Row(children: [
        Icon(info.icon, color: const Color(0xFF00E5FF), size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'Auto-detected from device firmware',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
        const Icon(Icons.verified, color: Color(0xFF00E5FF), size: 16),
      ]),
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
    return LinearProgressIndicator(
      value: currentIndex < 0 ? null : (currentIndex + 1) / steps.length,
      backgroundColor: const Color(0xFF1E2736),
      color: const Color(0xFF00E5FF),
      borderRadius: BorderRadius.circular(4),
      minHeight: 4,
    );
  }

  // ── Wi-Fi network picker ───────────────────────────────────────────────────

  Widget _buildSsidSection() {
    if (_isLoadingDeviceInfo) {
      return _buildDisabledField(
        icon: Icons.wifi_find,
        label: 'Scanning for Wi-Fi networks…',
        trailing: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF00E5FF)),
        ),
      );
    }

    final nets = _deviceInfo?.networks;

    if (nets != null && nets.isNotEmpty && !_manualSsidEntry) {
      return _buildNetworkDropdown(nets);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTextField(
          controller: _ssidCtrl,
          label: 'Wi-Fi Network Name (SSID)',
          icon: Icons.wifi,
          onChanged: (_) => setState(() {}),
        ),
        if (nets != null && nets.isNotEmpty) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _manualSsidEntry = false),
              child: const Text('Pick from list',
                  style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNetworkDropdown(List<WifiNetwork> networks) {
    final currentSsid = _ssidCtrl.text;
    final inList = networks.any((n) => n.ssid == currentSsid);
    if (!inList) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ssidCtrl.text.isEmpty) {
          setState(() => _ssidCtrl.text = networks.first.ssid);
        }
      });
    }

    final selectedSsid = inList ? currentSsid : networks.first.ssid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: selectedSsid,
          dropdownColor: const Color(0xFF121826),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Wi-Fi Network',
            labelStyle: const TextStyle(color: Colors.white38),
            prefixIcon: const Icon(Icons.wifi, color: Color(0xFF00E5FF)),
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
          items: networks
              .map((n) => DropdownMenuItem(
                    value: n.ssid,
                    child: Row(children: [
                      Icon(Icons.wifi, size: 18, color: _signalColor(n.signalLevel)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(n.ssid,
                              overflow: TextOverflow.ellipsis)),
                      Text('${n.rssi} dBm',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ]),
                  ))
              .toList(),
          onChanged: _inProgress
              ? null
              : (v) => setState(() => _ssidCtrl.text = v ?? selectedSsid),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() => _manualSsidEntry = true),
            child: const Text('Type manually',
                style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _buildDisabledField({
    required IconData icon,
    required String label,
    required Widget trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(icon, color: const Color(0xFF00E5FF)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 14)),
        ),
        trailing,
      ]),
    );
  }

  Color _signalColor(int level) {
    switch (level) {
      case 3:  return Colors.greenAccent;
      case 2:  return Colors.lightGreenAccent;
      case 1:  return Colors.orangeAccent;
      default: return Colors.redAccent;
    }
  }

  // ── Fallback options ──────────────────────────────────────────────────────

  Widget _buildFallbackOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionDivider("Can't scan the QR code?"),
        const SizedBox(height: 10),

        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: _showManualEntry
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF00E5FF),
              side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.keyboard, size: 18),
            label: const Text('Enter pair code manually'),
            onPressed: () => setState(() => _showManualEntry = true),
          ),
          secondChild: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _pairCodeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 6,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[A-Fa-f0-9]')),
                    ],
                    style: const TextStyle(
                        color: Colors.white,
                        letterSpacing: 4,
                        fontSize: 18,
                        fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      labelText: 'Pair code (6 characters from label)',
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
                          borderSide:
                              const BorderSide(color: Color(0xFF00E5FF))),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _pairCodeCtrl.text.trim().length == 6
                      ? _submitManualCode
                      : null,
                  child: const Text('Find',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => setState(() => _showManualEntry = false),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),
        _buildSectionDivider('or'),
        const SizedBox(height: 10),

        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF00E5FF),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          icon: _isScanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF00E5FF)))
              : const Icon(Icons.bluetooth_searching, size: 18),
          label: Text(_isScanning
              ? 'Scanning for nearby devices…'
              : 'Scan for nearby DSGV devices'),
          onPressed: _isScanning ? null : _scanNearbyDevices,
        ),

        if (_nearbyDevices.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF121826),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.2)),
            ),
            child: Column(
              children: _nearbyDevices.map((device) {
                return ListTile(
                  leading: const Icon(Icons.bluetooth,
                      color: Color(0xFF00E5FF), size: 20),
                  title: Text(
                    device.platformName,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      color: Colors.white38, size: 20),
                  onTap: () => _selectNearbyDevice(device),
                );
              }).toList(),
            ),
          ),
        ],
      ],
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
    final isDSGV = _parsedQr?.type == _QrType.dsgvProvision;
    return Text(
      isDSGV
          ? 'Wi-Fi credentials are sent directly to your device\n'
            'over an encrypted BLE channel. They are never uploaded\n'
            'to any server.'
          : 'Device pairing uses a secure commissioning flow\n'
            'to onboard your device.',
      textAlign: TextAlign.center,
      style:
          const TextStyle(color: Colors.white24, fontSize: 11, height: 1.6),
    );
  }

  Widget _buildStatusBanner() {
    if (_inProgress) {
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
          border: Border.all(
              color: const Color(0xFF00C853).withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.check_circle_rounded,
                color: Color(0xFF00C853), size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Provisioned successfully',
                    style: TextStyle(
                        color: Color(0xFF00C853),
                        fontWeight: FontWeight.w600,
                        fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _statusMessage!,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A0707),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: Colors.redAccent.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_rounded, color: Colors.redAccent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Provisioning failed',
                  style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                      fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  _statusMessage!,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
