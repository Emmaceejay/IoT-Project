import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../domain/services/matter_commissioning_service.dart';

/// Matter QR Pairing Screen
///
/// Guides the user through commissioning a new Matter device.
/// Scans a Matter QR code (MT: prefix) with the phone camera,
/// then triggers the OS-native Matter commissioning flow.
class MatterPairingScreen extends ConsumerStatefulWidget {
  const MatterPairingScreen({super.key});

  @override
  ConsumerState<MatterPairingScreen> createState() =>
      _MatterPairingScreenState();
}

class _MatterPairingScreenState extends ConsumerState<MatterPairingScreen> {
  final _nameController = TextEditingController();
  final _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool _isPairing = false;
  bool _scannerActive = true;
  String? _scannedCode;
  String? _statusMessage;
  bool _success = false;

  @override
  void dispose() {
    _nameController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    final barcode = capture.barcodes.firstOrNull;
    final raw = barcode?.rawValue;
    if (raw == null || !raw.startsWith('MT:')) return;

    setState(() {
      _scannedCode = raw;
      _scannerActive = false;
      _statusMessage = 'QR code captured. Enter a name and tap Commission.';
    });
    _scannerController.stop();
  }

  void _resetScanner() {
    setState(() {
      _scannedCode = null;
      _scannerActive = true;
      _statusMessage = null;
      _success = false;
    });
    _scannerController.start();
  }

  Future<void> _startPairing() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Please enter a device name.');
      return;
    }
    if (_scannedCode == null) {
      setState(() => _statusMessage = 'Please scan the device QR code first.');
      return;
    }

    setState(() {
      _isPairing = true;
      _statusMessage = 'Commissioning Matter device…';
      _success = false;
    });

    final service = ref.read(matterCommissioningProvider);
    final result = await service.commissionDevice(
      qrCodeString: _scannedCode,
      assignedName: _nameController.text.trim(),
    );

    setState(() {
      _isPairing = false;
      _statusMessage = result.message;
      _success = result.success;
    });

    if (result.success) {
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.of(context).pop();
    }
  }

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
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── QR Scanner / Preview ────────────────────────────────
            ClipRRect(
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
                    ? Stack(
                        children: [
                          MobileScanner(
                            controller: _scannerController,
                            onDetect: _onBarcodeDetected,
                          ),
                          // Overlay hint
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              color: Colors.black54,
                              child: const Text(
                                'Point at Matter QR code (MT:…)',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.check_circle,
                              size: 56, color: Color(0xFF00E5FF)),
                          const SizedBox(height: 8),
                          Text(
                            'Scanned: $_scannedCode',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
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
            ),

            const SizedBox(height: 28),

            // ── Device Name Input ──────────────────────────────────
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Device Name (e.g., Kitchen Light)',
                labelStyle: const TextStyle(color: Colors.white38),
                prefixIcon:
                    const Icon(Icons.label_outline, color: Color(0xFF00E5FF)),
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
            ),

            const SizedBox(height: 20),

            // ── Status Message ─────────────────────────────────────
            if (_statusMessage != null) ...[
              Text(
                _statusMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color:
                      _success ? const Color(0xFF00E5FF) : Colors.redAccent,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ── Commission Button ──────────────────────────────────
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
              onPressed: (_isPairing || _scannedCode == null) ? null : _startPairing,
              icon: _isPairing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.bluetooth_searching),
              label: Text(
                _isPairing
                    ? 'Commissioning…'
                    : _scannedCode == null
                        ? 'Scan QR Code First'
                        : 'Commission Device',
              ),
            ),

            const Spacer(),

            // ── Info footer ────────────────────────────────────────
            const Text(
              'Pairing shares Wi-Fi credentials with your Matter\ndevice securely via BLE using the OS Matter stack.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
