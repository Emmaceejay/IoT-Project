import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:wifi_iot/wifi_iot.dart';
import '../../domain/services/ble_provisioning_service.dart';
import '../../domain/services/device_manager.dart';
import '../../domain/services/wifi_ap_provisioning_service.dart';

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
  _DevicePreset(label: '1-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay'],                                        relayCount: 1),
  _DevicePreset(label: '2-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2'],                             relayCount: 2),
  _DevicePreset(label: '3-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2', 'relay_3'],                  relayCount: 3),
  _DevicePreset(label: '4-Gang Switch',  deviceType: 'Switch',     capabilities: ['relay', 'relay_2', 'relay_3', 'relay_4'],       relayCount: 4),
  _DevicePreset(label: 'Dimmer',         deviceType: 'Dimmer',     capabilities: ['relay', 'brightness'],                         relayCount: 1),
  _DevicePreset(label: 'Color Temp',     deviceType: 'Light',      capabilities: ['relay', 'brightness', 'color_temp'],           relayCount: 1),
  _DevicePreset(label: 'RGB Light',      deviceType: 'Light',      capabilities: ['relay', 'brightness', 'rgb'],                  relayCount: 1),
  _DevicePreset(label: 'Temp Sensor',    deviceType: 'Sensor',     capabilities: ['temperature', 'humidity'],                     relayCount: 0),
  _DevicePreset(label: 'Motion Sensor',  deviceType: 'Sensor',     capabilities: ['motion'],                                      relayCount: 0),
  _DevicePreset(label: 'Contact Sensor', deviceType: 'Sensor',     capabilities: ['contact'],                                     relayCount: 0),
  _DevicePreset(label: 'Thermostat',     deviceType: 'Thermostat', capabilities: ['temperature', 'hvac_mode'],                    relayCount: 1),
];

// ── QR parsing ────────────────────────────────────────────────────────────────

class _ParsedQr {
  final String raw;
  final String dsgvDeviceName;
  const _ParsedQr(this.raw, this.dsgvDeviceName);

  static _ParsedQr? tryParse(String raw) {
    if (!raw.startsWith('dsgv://provision')) return null;
    final uri  = Uri.tryParse(raw);
    final name = uri?.queryParameters['name'];
    if (name == null || name.isEmpty) return null;
    return _ParsedQr(raw, name);
  }
}

// ── Enums ─────────────────────────────────────────────────────────────────────

enum _ProvisionMethod { none, qr, pairCode, bleScan, wifiAp }
enum _WifiApStep      { scan, connect, form, sending }
enum _ProvisionResult { none, success, failed }

// ── Screen ────────────────────────────────────────────────────────────────────

class DevicePairingScreen extends ConsumerStatefulWidget {
  const DevicePairingScreen({super.key});

  @override
  ConsumerState<DevicePairingScreen> createState() =>
      _DevicePairingScreenState();
}

class _DevicePairingScreenState extends ConsumerState<DevicePairingScreen> {
  // Controllers
  final _nameCtrl      = TextEditingController();
  final _ssidCtrl      = TextEditingController();
  final _passwordCtrl  = TextEditingController();
  final _pairCodeCtrl  = TextEditingController();
  final _scannerCtrl   = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  // Method selection
  _ProvisionMethod _method = _ProvisionMethod.none;

  // QR flow
  _ParsedQr? _parsedQr;
  bool       _scannerActive = false;

  // Shared BLE credential form state
  bool            _obscurePassword  = true;
  _DevicePreset   _selectedPreset   = _kDevicePresets.first;
  bool            _inProgress       = false;
  String?         _statusMessage;
  bool            _isSuccess        = false;
  ProvisioningStep? _provStep;
  _ProvisionResult  _result         = _ProvisionResult.none;
  String            _resultMessage  = '';

  // WiFi SSID scan (for credential form)
  List<String> _scannedSsids    = [];
  bool         _ssidScanning    = false;
  bool         _ssidManualMode  = false;
  bool         _passwordExpanded = false;

  // BLE scan flow
  List<ScanResult> _bleDevices    = [];
  bool             _bleScanning   = false;
  StreamSubscription<List<ScanResult>>? _bleScanSub;
  String?          _selectedBleName;

  // WiFi AP flow
  _WifiApStep            _wifiApStep  = _WifiApStep.scan;
  List<WiFiAccessPoint>  _deviceAPs   = [];
  bool                   _apScanning  = false;
  WiFiAccessPoint?       _selectedAp;
  bool                   _apConnecting = false;
  bool                   _apConnected  = false;
  Timer?                 _apPingTimer;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    _pairCodeCtrl.dispose();
    _scannerCtrl.dispose();
    _bleScanSub?.cancel();
    FlutterBluePlus.stopScan();
    _apPingTimer?.cancel();
    super.dispose();
  }

  // ── Reset ────────────────────────────────────────────────────────────────

  void _resetToMethodPicker() {
    _bleScanSub?.cancel();
    _bleScanSub = null;
    FlutterBluePlus.stopScan();
    _apPingTimer?.cancel();
    _apPingTimer = null;
    if (_scannerActive) _scannerCtrl.stop();

    setState(() {
      _method          = _ProvisionMethod.none;
      _parsedQr        = null;
      _scannerActive   = false;
      _selectedBleName = null;
      _bleDevices      = [];
      _bleScanning     = false;
      _wifiApStep      = _WifiApStep.scan;
      _deviceAPs       = [];
      _apScanning      = false;
      _selectedAp      = null;
      _apConnecting    = false;
      _apConnected     = false;
      _nameCtrl.clear();
      _ssidCtrl.clear();
      _passwordCtrl.clear();
      _pairCodeCtrl.clear();
      _selectedPreset  = _kDevicePresets.first;
      _scannedSsids    = [];
      _ssidScanning    = false;
      _ssidManualMode  = false;
      _passwordExpanded = false;
      _inProgress      = false;
      _statusMessage   = null;
      _isSuccess       = false;
      _provStep        = null;
      _result          = _ProvisionResult.none;
      _resultMessage   = '';
    });
  }

  // ── WiFi SSID scan (for home Wi-Fi credential form) ──────────────────────

  Future<void> _scanNetworks() async {
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _ssidManualMode = true);
      return;
    }
    if (mounted) setState(() => _ssidScanning = true);
    try {
      final canStart =
          await WifiScan.instance.canStartScan(askPermissions: false);
      if (canStart == CanStartScan.yes) {
        await WifiScan.instance.startScan();
      }
      final results = await WifiScan.instance
          .getScannedResults(askPermissions: false);
      final ssids = results
          .map((r) => r.ssid)
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (mounted) setState(() => _scannedSsids = ssids);
    } catch (_) {
      if (mounted) setState(() => _ssidManualMode = true);
    } finally {
      if (mounted) setState(() => _ssidScanning = false);
    }
  }

  // ── QR scanner ───────────────────────────────────────────────────────────

  void _onBarcodeDetected(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    final parsed = _ParsedQr.tryParse(raw);
    if (parsed == null) {
      setState(() => _statusMessage =
          'Unrecognised QR code. Scan a DSGV provisioning QR (dsgv://…).');
      return;
    }

    _scannerCtrl.stop();
    setState(() {
      _parsedQr      = parsed;
      _scannerActive = false;
      _statusMessage = null;
    });
    _scanNetworks();
  }

  // ── BLE scan ─────────────────────────────────────────────────────────────

  Future<void> _startBleScan() async {
    final perm = await Permission.bluetoothScan.request();
    if (!perm.isGranted) {
      if (mounted) setState(() => _statusMessage = 'Bluetooth permission denied.');
      return;
    }
    setState(() {
      _bleDevices  = [];
      _bleScanning = true;
      _statusMessage = null;
    });

    _bleScanSub?.cancel();
    _bleScanSub = FlutterBluePlus.onScanResults.listen((results) {
      final filtered = results
          .where((r) => r.device.platformName.startsWith('DSGVHub_'))
          .toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));
      if (mounted) setState(() => _bleDevices = filtered);
    });

    await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 20));
    if (mounted) setState(() => _bleScanning = false);
  }

  void _selectBleDevice(ScanResult result) {
    _bleScanSub?.cancel();
    _bleScanSub = null;
    FlutterBluePlus.stopScan();
    setState(() {
      _selectedBleName = result.device.platformName;
      _bleScanning     = false;
    });
    _scanNetworks();
  }

  // ── WiFi AP flow ─────────────────────────────────────────────────────────

  Future<void> _startApScan() async {
    final perm = await Permission.locationWhenInUse.request();
    if (!perm.isGranted) {
      if (mounted) setState(() => _statusMessage = 'Location permission required to scan Wi-Fi.');
      return;
    }
    setState(() {
      _deviceAPs  = [];
      _apScanning = true;
      _statusMessage = null;
    });
    final aps = await WifiApProvisioningService.scanForDeviceAPs();
    if (mounted) {
      setState(() {
        _deviceAPs  = aps;
        _apScanning = false;
      });
    }
  }

  void _selectDeviceAp(WiFiAccessPoint ap) {
    setState(() {
      _selectedAp  = ap;
      _wifiApStep  = _WifiApStep.connect;
      _apConnected = false;
    });
    _startPingPolling();
  }

  void _startPingPolling() {
    _apPingTimer?.cancel();
    _apPingTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (await WifiApProvisioningService.pingOnce()) {
        if (mounted && !_apConnected) {
          _apPingTimer?.cancel();
          _apPingTimer = null;
          setState(() {
            _apConnected = true;
            _wifiApStep  = _WifiApStep.form;
          });
          _scanNetworks();
        }
      }
    });
  }

  Future<void> _tryAutoConnect() async {
    if (_selectedAp == null) return;
    setState(() => _apConnecting = true);
    try {
      await WiFiForIoTPlugin.connect(
        _selectedAp!.ssid,
        password: 'dsgvsetup',
        security: NetworkSecurity.WPA,
        joinOnce: true,
      );
    } catch (_) {}
    if (mounted) setState(() => _apConnecting = false);
  }

  Future<void> _startWifiApProvisioning() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Please enter a device name.');
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
      _wifiApStep    = _WifiApStep.sending;
      _statusMessage = null;
    });

    final stream = WifiApProvisioningService.provision(
      homeSsid:     _ssidCtrl.text.trim(),
      homePassword: _passwordCtrl.text,
      deviceType:   _selectedPreset.deviceType,
      capabilities: _selectedPreset.capabilities,
      relayCount:   _selectedPreset.relayCount,
    );

    await for (final res in stream) {
      if (!mounted) return;

      if (res.status == WifiApProvisionStatus.success) {
        if (res.authToken != null && res.deviceId != null) {
          final manager = ref.read(deviceManagerProvider.notifier);
          manager.setPendingToken(res.deviceId!, res.authToken!);
          manager
              .registerDevice(res.deviceId!, res.authToken!)
              .catchError((Object e) {
            debugPrint('[WiFi AP] Firebase registration failed: $e');
          });
        }
        setState(() {
          _result        = _ProvisionResult.success;
          _resultMessage = res.message ?? 'Device provisioned successfully!';
        });
        return;
      }

      if (res.status == WifiApProvisionStatus.failed) {
        setState(() {
          _result        = _ProvisionResult.failed;
          _resultMessage = res.message ?? 'Provisioning failed. Please try again.';
          _wifiApStep    = _WifiApStep.form;
        });
        return;
      }
    }
  }

  // ── BLE provisioning (QR / pair-code / BLE-scan methods) ─────────────────

  String? _bleDeviceName() => switch (_method) {
    _ProvisionMethod.qr       => _parsedQr?.dsgvDeviceName,
    _ProvisionMethod.pairCode => _pairCodeCtrl.text.trim().isEmpty
        ? null
        : 'DSGVHub_${_pairCodeCtrl.text.trim().toUpperCase()}',
    _ProvisionMethod.bleScan  => _selectedBleName,
    _                         => null,
  };

  Future<void> _startProvisioning() async {
    final deviceName = _bleDeviceName();
    if (deviceName == null) {
      setState(() => _statusMessage = 'No device selected.');
      return;
    }
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Please enter a device name.');
      return;
    }
    if (_ssidCtrl.text.trim().isEmpty) {
      setState(() =>
          _statusMessage = 'Please enter your Wi-Fi network name (SSID).');
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

    final stream = BleProvisioningService.provision(
      deviceName:   deviceName,
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
          manager.setPendingToken(
              status.provisionedDeviceId!, status.authToken!);
          manager
              .registerDevice(
                  status.provisionedDeviceId!, status.authToken!)
              .catchError((Object e) {
            debugPrint('[Pairing] Firebase registration failed: $e');
          });
        }
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
            _resultMessage =
                status.message ?? 'Provisioning failed. Please try again.';
          });
        }
        return;
      }
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

  bool get _canProvision {
    if (_inProgress || _result != _ProvisionResult.none) return false;
    if (_nameCtrl.text.trim().isEmpty)   return false;
    if (_ssidCtrl.text.trim().isEmpty)   return false;
    return switch (_method) {
      _ProvisionMethod.qr       => _parsedQr != null,
      _ProvisionMethod.pairCode => _pairCodeCtrl.text.trim().isNotEmpty,
      _ProvisionMethod.bleScan  => _selectedBleName != null,
      _                         => false,
    };
  }

  bool get _canProvisionWifiAp {
    return _wifiApStep == _WifiApStep.form &&
        _nameCtrl.text.trim().isNotEmpty &&
        _ssidCtrl.text.trim().isNotEmpty &&
        _passwordCtrl.text.isNotEmpty;
  }

  Color _rssiColor(int rssi) {
    if (rssi >= -60) return Colors.greenAccent;
    if (rssi >= -75) return Colors.orangeAccent;
    return Colors.redAccent;
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
                  if (_method == _ProvisionMethod.none)
                    _buildMethodPicker()
                  else ...[
                    if (!_inProgress && _wifiApStep != _WifiApStep.sending)
                      _buildBackButton(),
                    const SizedBox(height: 8),
                    _buildMethodFlow(),
                  ],
                  const SizedBox(height: 32),
                  _buildFooter(),
                ],
              ),
      ),
    );
  }

  // ── Method picker ─────────────────────────────────────────────────────────

  Widget _buildMethodPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'How would you like to add your device?',
          style: TextStyle(
              color: Colors.white70, fontSize: 15, height: 1.5),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(child: _buildMethodTile(
            icon: Icons.qr_code_scanner,
            title: 'Scan QR Code',
            subtitle: 'Scan the QR label on your device',
            onTap: () => setState(() => _method = _ProvisionMethod.qr),
          )),
          const SizedBox(width: 12),
          Expanded(child: _buildMethodTile(
            icon: Icons.dialpad_outlined,
            title: 'Enter Pair Code',
            subtitle: 'Type the code from your device label',
            onTap: () => setState(() => _method = _ProvisionMethod.pairCode),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _buildMethodTile(
            icon: Icons.bluetooth_searching,
            title: 'Scan BLE Devices',
            subtitle: 'Find nearby DSGV devices automatically',
            onTap: () {
              setState(() => _method = _ProvisionMethod.bleScan);
              _startBleScan();
            },
          )),
          const SizedBox(width: 12),
          Expanded(child: _buildMethodTile(
            icon: Icons.wifi_tethering,
            title: 'WiFi Setup',
            subtitle: 'Connect via device access point',
            onTap: () => setState(() => _method = _ProvisionMethod.wifiAp),
          )),
        ]),
      ],
    );
  }

  Widget _buildMethodTile({
    required IconData icon,
    required String   title,
    required String   subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          border:
              Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: const Color(0xFF00E5FF)),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 11, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackButton() {
    return TextButton.icon(
      onPressed: _resetToMethodPicker,
      icon: const Icon(Icons.arrow_back_ios,
          size: 14, color: Color(0xFF00E5FF)),
      label: const Text(
        'Choose different method',
        style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13),
      ),
    );
  }

  // ── Method flow dispatcher ────────────────────────────────────────────────

  Widget _buildMethodFlow() => switch (_method) {
    _ProvisionMethod.qr       => _buildQrFlow(),
    _ProvisionMethod.pairCode => _buildPairCodeFlow(),
    _ProvisionMethod.bleScan  => _buildBleScanFlow(),
    _ProvisionMethod.wifiAp   => _buildWifiApFlow(),
    _                         => const SizedBox.shrink(),
  };

  // ── QR flow ───────────────────────────────────────────────────────────────

  Widget _buildQrFlow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildScannerSection(),
        if (_parsedQr != null) ...[
          const SizedBox(height: 24),
          _buildBleCredentialForm(),
        ],
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
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
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
                        onPressed: () {
                          setState(() {
                            _parsedQr      = null;
                            _scannerActive = false;
                          });
                        },
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

  // ── Pair code flow ────────────────────────────────────────────────────────

  Widget _buildPairCodeFlow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          icon: Icons.dialpad_outlined,
          title: 'Enter Pair Code',
          subtitle: 'Type the 6-character code printed on your device label.',
        ),
        const SizedBox(height: 16),
        _buildTextField(
          controller: _pairCodeCtrl,
          label: 'Pair Code (e.g., A1B2C3)',
          icon: Icons.dialpad_outlined,
          onChanged: (_) => setState(() {}),
        ),
        if (_pairCodeCtrl.text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            const SizedBox(width: 4),
            const Icon(Icons.bluetooth, size: 13, color: Color(0xFF00E5FF)),
            const SizedBox(width: 6),
            Text(
              'Connects to: DSGVHub_${_pairCodeCtrl.text.trim().toUpperCase()}',
              style: const TextStyle(
                  color: Colors.white38, fontSize: 12),
            ),
          ]),
          const SizedBox(height: 24),
          _buildBleCredentialForm(),
        ],
      ],
    );
  }

  // ── BLE scan flow ─────────────────────────────────────────────────────────

  Widget _buildBleScanFlow() {
    if (_selectedBleName != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF121826),
              border: Border.all(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              const Icon(Icons.bluetooth_connected,
                  color: Color(0xFF00E5FF), size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_selectedBleName!,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    const Text('Device selected',
                        style: TextStyle(
                            color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _selectedBleName = null;
                  _bleDevices = [];
                }),
                child: const Text('Change',
                    style: TextStyle(
                        color: Color(0xFF00E5FF), fontSize: 12)),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          _buildBleCredentialForm(),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          icon: Icons.bluetooth_searching,
          title: 'Scan BLE Devices',
          subtitle: 'Searching for nearby DSGV devices.',
        ),
        const SizedBox(height: 16),
        if (_bleScanning) ...[
          const LinearProgressIndicator(
            backgroundColor: Color(0xFF1E2736),
            color: Color(0xFF00E5FF),
            minHeight: 3,
          ),
          const SizedBox(height: 12),
          const Text(
            'Scanning for DSGVHub devices…',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 16),
        ],
        if (_bleDevices.isEmpty && !_bleScanning) ...[
          Container(
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              color: const Color(0xFF121826),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF1E3A5F)),
            ),
            child: Column(
              children: [
                const Icon(Icons.bluetooth_disabled,
                    size: 40, color: Colors.white24),
                const SizedBox(height: 12),
                const Text(
                  'No DSGV devices found nearby.',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E2A3A),
                    foregroundColor: const Color(0xFF00E5FF),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _startBleScan,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Scan Again'),
                ),
              ],
            ),
          ),
        ] else ...[
          ..._bleDevices.map((r) => _buildBleDeviceTile(r)),
          if (_bleScanning)
            const SizedBox.shrink()
          else ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _startBleScan,
              icon: const Icon(Icons.refresh,
                  size: 14, color: Color(0xFF00E5FF)),
              label: const Text('Rescan',
                  style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13)),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildBleDeviceTile(ScanResult result) {
    final name = result.device.platformName;
    final rssi = result.rssi;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _selectBleDevice(result),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF121826),
            border: Border.all(color: const Color(0xFF1E3A5F)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const Icon(Icons.bluetooth,
                size: 20, color: Color(0xFF00E5FF)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(name,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14)),
            ),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _rssiColor(rssi),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$rssi dBm',
              style:
                  const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ]),
        ),
      ),
    );
  }

  // ── WiFi AP flow ──────────────────────────────────────────────────────────

  Widget _buildWifiApFlow() => switch (_wifiApStep) {
    _WifiApStep.scan     => _buildWifiApScanSection(),
    _WifiApStep.connect  => _buildWifiApConnectSection(),
    _WifiApStep.form     => _buildWifiApFormSection(),
    _WifiApStep.sending  => _buildWifiApSendingSection(),
  };

  Widget _buildWifiApScanSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          icon: Icons.wifi_tethering,
          title: 'WiFi Setup',
          subtitle: 'Find a DSGV device broadcasting its setup network.',
        ),
        const SizedBox(height: 16),
        if (_apScanning) ...[
          const LinearProgressIndicator(
            backgroundColor: Color(0xFF1E2736),
            color: Color(0xFF00E5FF),
            minHeight: 3,
          ),
          const SizedBox(height: 12),
          const Text(
            'Scanning for DSGV setup networks…',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 16),
        ],
        if (!_apScanning && _deviceAPs.isEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              color: const Color(0xFF121826),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF1E3A5F)),
            ),
            child: Column(
              children: [
                const Icon(Icons.wifi_off, size: 40, color: Colors.white24),
                const SizedBox(height: 12),
                const Text(
                  'No DSGV setup networks found.',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
                const SizedBox(height: 6),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Make sure the device is powered on for the first time '
                    'and in range.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white24, fontSize: 11, height: 1.5),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E2A3A),
                    foregroundColor: const Color(0xFF00E5FF),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _startApScan,
                  icon: const Icon(Icons.wifi_find, size: 16),
                  label: const Text('Scan for Devices'),
                ),
              ],
            ),
          ),
        ] else if (!_apScanning) ...[
          ..._deviceAPs.map((ap) => _buildApTile(ap)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _startApScan,
            icon: const Icon(Icons.refresh,
                size: 14, color: Color(0xFF00E5FF)),
            label: const Text('Rescan',
                style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13)),
          ),
        ] else ...[
          // Still scanning but have partial results
          ..._deviceAPs.map((ap) => _buildApTile(ap)),
        ],
      ],
    );
  }

  Widget _buildApTile(WiFiAccessPoint ap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _selectDeviceAp(ap),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF121826),
            border: Border.all(color: const Color(0xFF1E3A5F)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const Icon(Icons.wifi_tethering,
                size: 20, color: Color(0xFF00E5FF)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(ap.ssid,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14)),
            ),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _rssiColor(ap.level),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${ap.level} dBm',
              style:
                  const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildWifiApConnectSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          icon: Icons.wifi_lock,
          title: 'Connect to Device',
          subtitle: 'Join the device\'s Wi-Fi network so the app can reach it.',
        ),
        const SizedBox(height: 20),

        // AP credentials card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF121826),
            border: Border.all(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildApCredRow(
                  Icons.wifi, 'Network Name', _selectedAp?.ssid ?? ''),
              const Divider(color: Color(0xFF1E3A5F), height: 20),
              _buildApCredRow(
                  Icons.lock_outline, 'Password', 'dsgvsetup'),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // Steps instruction
        const Text(
          '1. Open your phone\'s Wi-Fi settings\n'
          '2. Connect to the network shown above\n'
          '3. Return to this app — it will detect the connection automatically',
          style: TextStyle(
              color: Colors.white54, fontSize: 13, height: 1.7),
        ),

        const SizedBox(height: 20),

        // Android: auto-connect button
        if (Platform.isAndroid) ...[
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E2A3A),
              foregroundColor: const Color(0xFF00E5FF),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _apConnecting ? null : _tryAutoConnect,
            icon: _apConnecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF00E5FF)),
                  )
                : const Icon(Icons.wifi, size: 18),
            label: Text(_apConnecting
                ? 'Connecting…'
                : 'Connect Automatically'),
          ),
          const SizedBox(height: 12),
        ],

        // Ping status
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0A1A0A),
            border: Border.all(
                color: _apConnected
                    ? const Color(0xFF00E695).withValues(alpha: 0.5)
                    : const Color(0xFF1E3A5F)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            _apConnected
                ? const Icon(Icons.check_circle_outline,
                    size: 16, color: Color(0xFF00E695))
                : const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF00E5FF)),
                  ),
            const SizedBox(width: 10),
            Text(
              _apConnected
                  ? 'Connected! Moving to next step…'
                  : 'Checking connection…',
              style: TextStyle(
                color: _apConnected
                    ? const Color(0xFF00E695)
                    : Colors.white54,
                fontSize: 13,
              ),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _buildApCredRow(IconData icon, String label, String value) {
    return Row(children: [
      Icon(icon, size: 16, color: const Color(0xFF00E5FF)),
      const SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style:
                const TextStyle(color: Colors.white38, fontSize: 11)),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5)),
      ]),
    ]);
  }

  Widget _buildWifiApFormSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF001A0A),
            border: Border.all(
                color: const Color(0xFF00E695).withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const Icon(Icons.check_circle_outline,
                size: 16, color: Color(0xFF00E695)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Connected to ${_selectedAp?.ssid ?? 'device'}',
                style: const TextStyle(
                    color: Color(0xFF00E695), fontSize: 13),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        _buildSectionHeader(
          icon: Icons.home_outlined,
          title: 'Home Wi-Fi Credentials',
          subtitle:
              'Enter your home network details — the device will connect to it after setup.',
        ),
        const SizedBox(height: 16),
        _buildBleCredentialForm(provisionButton: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00E5FF),
            foregroundColor: Colors.black,
            disabledBackgroundColor:
                const Color(0xFF00E5FF).withValues(alpha: 0.4),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _canProvisionWifiAp ? _startWifiApProvisioning : null,
          icon: const Icon(Icons.send_rounded),
          label: const Text('Send to Device'),
        )),
      ],
    );
  }

  Widget _buildWifiApSendingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 40),
        const Center(
          child: SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Color(0xFF00E5FF),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Sending credentials to device…',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, fontSize: 15),
        ),
        const SizedBox(height: 8),
        const Text(
          'Do not leave this screen.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  // ── Shared BLE credential form ────────────────────────────────────────────

  Widget _buildBleCredentialForm({Widget? provisionButton}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTextField(
          controller: _nameCtrl,
          label: 'Device Name (e.g., Kitchen Switch)',
          icon: Icons.label_outline,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        _buildPresetDropdown(),
        const SizedBox(height: 16),
        _buildSsidField(),
        const SizedBox(height: 12),
        _buildPasswordField(),
        const SizedBox(height: 20),

        if (_inProgress && _provStep != null) ...[
          _buildProvisioningProgress(_provStep!),
          const SizedBox(height: 12),
        ],

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

        provisionButton ??
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
              label: Text(_inProgress ? 'Provisioning…' : 'Provision Device'),
            ),
      ],
    );
  }

  // ── Result card ───────────────────────────────────────────────────────────

  Widget _buildResultCard() {
    final isSuccess = _result == _ProvisionResult.success;
    final iconData   = isSuccess ? Icons.check_circle_rounded : Icons.cancel_rounded;
    final iconColor  = isSuccess ? const Color(0xFF00E695) : const Color(0xFFFF5252);
    final cardColor  = isSuccess
        ? const Color(0xFF00E695).withValues(alpha: 0.08)
        : const Color(0xFFFF5252).withValues(alpha: 0.08);
    final borderColor = isSuccess
        ? const Color(0xFF00E695).withValues(alpha: 0.4)
        : const Color(0xFFFF5252).withValues(alpha: 0.4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 40),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: cardColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              Icon(iconData, size: 72, color: iconColor),
              const SizedBox(height: 20),
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
              Text(
                _resultMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 14, height: 1.6),
              ),
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
                              color: Colors.white38,
                              fontSize: 12,
                              height: 1.5),
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
        if (isSuccess) ...[
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
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _resetToMethodPicker,
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: const Text('Provision Another Device'),
          ),
        ] else ...[
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _resetToMethodPicker,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try Again',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),
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

  // ── Widget helpers ─────────────────────────────────────────────────────────

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF00E5FF).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: const Color(0xFF00E5FF), size: 22),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: const TextStyle(
                    color: Colors.white38, fontSize: 12, height: 1.4)),
          ],
        ),
      ),
    ]);
  }

  Widget _buildSsidField() {
    if (_ssidManualMode) {
      return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: _buildTextField(
            controller: _ssidCtrl,
            label: 'Wi-Fi Network Name (SSID)',
            icon: Icons.wifi,
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Pick from list',
          child: IconButton(
            icon: const Icon(Icons.list, color: Color(0xFF00E5FF)),
            onPressed: () => setState(() {
              _ssidManualMode = false;
              if (_scannedSsids.isEmpty) _scanNetworks();
            }),
          ),
        ),
      ]);
    }

    final dropdownItems = [
      ..._scannedSsids.map(
        (s) => DropdownMenuItem<String>(
          value: s,
          child: Text(s,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white)),
        ),
      ),
      const DropdownMenuItem<String>(
        value: '__manual__',
        child: Text('Type manually…',
            style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13)),
      ),
    ];

    final currentValue =
        _scannedSsids.contains(_ssidCtrl.text) ? _ssidCtrl.text : null;

    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        child: DropdownButtonFormField<String>(
          decoration: InputDecoration(
            labelText: 'Wi-Fi Network',
            prefixIcon: const Icon(Icons.wifi, color: Color(0xFF00E5FF)),
            labelStyle: const TextStyle(color: Colors.white54),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF1E3A5F)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF00E5FF)),
            ),
            filled: true,
            fillColor: const Color(0xFF121826),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          ),
          dropdownColor: const Color(0xFF121826),
          hint: Text(
            _ssidScanning ? 'Scanning…' : 'Select a network',
            style: const TextStyle(color: Colors.white38),
          ),
          value: currentValue,
          items: _ssidScanning ? [] : dropdownItems,
          onChanged: (val) {
            if (val == '__manual__') {
              setState(() => _ssidManualMode = true);
            } else if (val != null) {
              setState(() => _ssidCtrl.text = val);
            }
          },
        ),
      ),
      const SizedBox(width: 8),
      _ssidScanning
          ? const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF00E5FF)),
            )
          : Tooltip(
              message: 'Rescan networks',
              child: IconButton(
                icon: const Icon(Icons.refresh, color: Color(0xFF00E5FF)),
                onPressed: _scanNetworks,
              ),
            ),
    ]);
  }

  Widget _buildPasswordField() {
    final hasPassword = _passwordCtrl.text.isNotEmpty;
    final maskedDots = hasPassword
        ? '●' * _passwordCtrl.text.length.clamp(0, 14)
        : 'Tap to enter';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () =>
            setState(() => _passwordExpanded = !_passwordExpanded),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF121826),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF1E3A5F)),
          ),
          child: Row(children: [
            const Icon(Icons.lock_outline,
                color: Color(0xFF00E5FF), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Wi-Fi Password',
                      style: TextStyle(
                          color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 2),
                  Text(
                    maskedDots,
                    style: TextStyle(
                      color: hasPassword
                          ? Colors.white70
                          : Colors.white24,
                      fontSize: 14,
                      letterSpacing: hasPassword ? 2 : 0,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              _passwordExpanded
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              color: Colors.white38,
            ),
          ]),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: _passwordExpanded
            ? Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _buildTextField(
                  controller: _passwordCtrl,
                  label: 'Wi-Fi Password',
                  icon: Icons.lock_outline,
                  obscureText: _obscurePassword,
                  onChanged: (_) => setState(() {}),
                  suffix: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: Colors.white38,
                      size: 20,
                    ),
                    onPressed: () => setState(
                        () => _obscurePassword = !_obscurePassword),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    ]);
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
          .map((p) => DropdownMenuItem(value: p, child: Text(p.label)))
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
    final idx = steps.indexOf(step);
    return LinearProgressIndicator(
      value: idx < 0 ? null : (idx + 1) / steps.length,
      backgroundColor: const Color(0xFF1E2736),
      color: const Color(0xFF00E5FF),
      borderRadius: BorderRadius.circular(4),
      minHeight: 4,
    );
  }

  Widget _buildFooter() {
    return const Text(
      'Wi-Fi credentials are sent directly to your device.\n'
      'They are never uploaded to any server.',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.white24, fontSize: 11, height: 1.6),
    );
  }
}
