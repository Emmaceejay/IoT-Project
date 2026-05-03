import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/matter_commissioning_service.dart';

/// Matter QR Pairing Screen
///
/// Guides the user through commissioning a new Matter device.
/// On real hardware, triggers the OS-native Matter QR flow.
/// Shows progress clearly with animated feedback.
class MatterPairingScreen extends ConsumerStatefulWidget {
  const MatterPairingScreen({super.key});

  @override
  ConsumerState<MatterPairingScreen> createState() => _MatterPairingScreenState();
}

class _MatterPairingScreenState extends ConsumerState<MatterPairingScreen> {
  final _nameController = TextEditingController();
  bool _isPairing = false;
  String? _statusMessage;
  bool _success = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _startPairing() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _statusMessage = 'Please enter a device name.');
      return;
    }

    setState(() {
      _isPairing = true;
      _statusMessage = 'Scanning for Matter device...';
      _success = false;
    });

    final service = ref.read(matterCommissioningProvider);
    final result = await service.commissionDevice(
      qrCodeString: null, // In production: pass scanned QR code value
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
        title: const Text('Pair New Device',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── QR Illustration ────────────────────────────────────
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.qr_code_2, size: 80, color: Color(0xFF00E5FF)),
                  SizedBox(height: 12),
                  Text(
                    'Point camera at your device\'s\nMatter QR Code',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

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
                  borderSide:
                      const BorderSide(color: Color(0xFF00E5FF)),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // ── Status Message ─────────────────────────────────────
            if (_statusMessage != null) ...[
              Text(
                _statusMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _success ? const Color(0xFF00E5FF) : Colors.redAccent,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ── Pairing Button ─────────────────────────────────────
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _isPairing ? null : _startPairing,
              icon: _isPairing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.bluetooth_searching),
              label: Text(_isPairing ? 'Commissioning...' : 'Scan & Commission Device'),
            ),

            const Spacer(),

            // ── Info footer ────────────────────────────────────────
            const Text(
              'The pairing process uses your phone\'s OS to securely\nshare Wi-Fi credentials with your Matter device via BLE.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
