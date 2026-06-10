import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_scan/wifi_scan.dart';
import '../../domain/models/smart_device.dart';
import '../../domain/services/device_manager.dart';
import 'device_pairing_screen.dart';

class BulkWifiScreen extends ConsumerStatefulWidget {
  const BulkWifiScreen({super.key});

  @override
  ConsumerState<BulkWifiScreen> createState() => _BulkWifiScreenState();
}

class _BulkWifiScreenState extends ConsumerState<BulkWifiScreen> {
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _obscurePass = true;
  List<WiFiAccessPoint> _scannedNetworks = [];
  bool _isScanning = false;
  bool _showNetworkList = false;

  // deviceId → 'idle' | 'pending' | 'sent' | 'error'
  Map<String, String> _results = {};
  bool _applying = false;

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  // ── WiFi scan ──────────────────────────────────────────────────────────────

  Future<void> _scanNetworks() async {
    FocusScope.of(context).unfocus();

    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      _showInfo('Location permission is required to scan for Wi-Fi networks.');
      return;
    }

    final canScan = await WiFiScan.instance.canStartScan(askPermissions: true);
    if (canScan != CanStartScan.yes) {
      _showInfo('Wi-Fi scanning is not available on this device. Please type the network name.');
      return;
    }

    setState(() {
      _isScanning = true;
      _showNetworkList = false;
    });

    await WiFiScan.instance.startScan();
    final results = await WiFiScan.instance.getScannedResults();
    final networks = results.where((r) => r.ssid.isNotEmpty).toList()
      ..sort((a, b) => b.level.compareTo(a.level));

    if (!mounted) return;
    setState(() {
      _scannedNetworks = networks;
      _isScanning = false;
      _showNetworkList = networks.isNotEmpty;
      if (networks.isEmpty) {
        _showInfo('No networks found nearby. Try scanning again.');
      }
    });
  }

  void _showInfo(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1E2A3A),
      ),
    );
  }

  int _wifiSignalLevel(int rssi) {
    if (rssi >= -50) return 4;
    if (rssi >= -60) return 3;
    if (rssi >= -70) return 2;
    return 1;
  }

  bool _isSecuredNetwork(String capabilities) =>
      capabilities.contains('WPA') || capabilities.contains('WEP');

  // ── Apply ──────────────────────────────────────────────────────────────────

  Future<void> _applyAll(List<SmartDevice> devices) async {
    final ssid = _ssidCtrl.text.trim();
    if (ssid.isEmpty) {
      _showInfo('Enter the network name (SSID) first.');
      return;
    }
    final pass = _passCtrl.text;
    final manager = ref.read(deviceManagerProvider.notifier);

    setState(() {
      _applying = true;
      _results = {
        for (final d in devices)
          d.uniqueDeviceId: d.status == DeviceStatus.online ? 'pending' : 'skipped',
      };
    });

    for (final device in devices) {
      if (device.status != DeviceStatus.online) continue;
      if (device.authToken == null) {
        setState(() => _results[device.uniqueDeviceId] = 'error');
        continue;
      }
      try {
        await manager.changeDeviceWifi(
          device.uniqueDeviceId,
          device.authToken!,
          ssid,
          pass,
        );
        if (!mounted) return;
        setState(() => _results[device.uniqueDeviceId] = 'sent');
      } catch (_) {
        if (!mounted) return;
        setState(() => _results[device.uniqueDeviceId] = 'error');
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }

    if (!mounted) return;
    setState(() => _applying = false);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(deviceManagerProvider).valueOrNull ?? [];
    final offlineCount =
        devices.where((d) => d.status != DeviceStatus.online).length;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Bulk Wi-Fi Change',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Offline warning banner ────────────────────────────────────
          if (offlineCount > 0) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: Colors.amber.withValues(alpha: 0.35)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline,
                      color: Colors.amber, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$offlineCount device${offlineCount > 1 ? 's are' : ' is'} '
                      'offline and cannot receive Wi-Fi changes over MQTT. '
                      'Tap "BLE" next to each offline device to update it via Bluetooth.',
                      style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

          // ── New network credentials ───────────────────────────────────
          _sectionLabel('New Network'),
          _card(
            child: Column(
              children: [
                TextField(
                  controller: _ssidCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  decoration: InputDecoration(
                    labelText: 'Network name (SSID)',
                    labelStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.wifi,
                        color: Color(0xFF00E5FF), size: 20),
                    suffixIcon: IconButton(
                      icon: _isScanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: Color(0xFF00E5FF)))
                          : const Icon(Icons.wifi_find,
                              color: Color(0xFF00E5FF), size: 20),
                      tooltip: 'Scan for networks',
                      onPressed: _isScanning ? null : _scanNetworks,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0A0E1A),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: Color(0xFF00E5FF))),
                  ),
                  onChanged: (_) =>
                      setState(() => _showNetworkList = false),
                ),
                if (_showNetworkList) ...[
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 220),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0E1A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      physics: const ClampingScrollPhysics(),
                      itemCount: _scannedNetworks.length,
                      itemBuilder: (_, i) {
                        final n = _scannedNetworks[i];
                        final level = _wifiSignalLevel(n.level);
                        final secured = _isSecuredNetwork(n.capabilities);
                        final signalColor = level >= 3
                            ? const Color(0xFF00E5FF)
                            : level == 2
                                ? const Color(0xFF00E5FF)
                                    .withValues(alpha: 0.55)
                                : const Color(0xFF00E5FF)
                                    .withValues(alpha: 0.3);
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            _ssidCtrl.text = n.ssid;
                            setState(() => _showNetworkList = false);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            child: Row(
                              children: [
                                Icon(Icons.wifi,
                                    size: 18, color: signalColor),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(n.ssid,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13)),
                                ),
                                if (secured)
                                  const Icon(Icons.lock_outline,
                                      size: 14, color: Colors.white38),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: _passCtrl,
                  obscureText: _obscurePass,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  decoration: InputDecoration(
                    labelText: 'Password (leave blank if open network)',
                    labelStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.lock_outline,
                        color: Color(0xFF00E5FF), size: 20),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePass
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: Colors.white38,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass),
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0A0E1A),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: Color(0xFF00E5FF))),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      disabledBackgroundColor:
                          const Color(0xFF00E5FF).withValues(alpha: 0.3),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: (_applying ||
                            _ssidCtrl.text.trim().isEmpty ||
                            devices.isEmpty)
                        ? null
                        : () => _applyAll(devices),
                    icon: _applying
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black))
                        : const Icon(Icons.sync_alt, size: 18),
                    label: Text(
                      _applying
                          ? 'Applying…'
                          : 'Apply to All Online Devices',
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Device list ───────────────────────────────────────────────
          const SizedBox(height: 24),
          _sectionLabel('Devices (${devices.length})'),
          if (devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text('No provisioned devices found.',
                    style: TextStyle(color: Colors.white38, fontSize: 13)),
              ),
            )
          else
            _card(
              child: Column(
                children: [
                  for (int i = 0; i < devices.length; i++) ...[
                    if (i > 0)
                      Divider(
                          height: 20,
                          thickness: 1,
                          color: Colors.white.withValues(alpha: 0.06)),
                    _DeviceRow(
                      device: devices[i],
                      result: _results[devices[i].uniqueDeviceId] ?? 'idle',
                      applying: _applying,
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _sectionLabel(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
      );

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: child,
      );
}

// ── Device row ────────────────────────────────────────────────────────────────

class _DeviceRow extends StatelessWidget {
  final SmartDevice device;
  final String result;
  final bool applying;

  const _DeviceRow({
    required this.device,
    required this.result,
    required this.applying,
  });

  @override
  Widget build(BuildContext context) {
    final isOnline = device.status == DeviceStatus.online;
    final statusColor =
        isOnline ? const Color(0xFF00E5FF) : Colors.white38;

    Widget trailing;
    if (!isOnline) {
      trailing = GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => const DevicePairingScreen(bleScanMode: true)),
        ),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: Colors.amber.withValues(alpha: 0.4)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth, size: 12, color: Colors.amber),
              SizedBox(width: 4),
              Text('BLE',
                  style: TextStyle(
                      color: Colors.amber,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
    } else {
      trailing = switch (result) {
        'pending' => applying
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: Color(0xFF00E5FF)))
            : const SizedBox(width: 16),
        'sent' => const Icon(Icons.check_circle_outline,
            color: Color(0xFF00E5FF), size: 20),
        'error' => const Icon(Icons.error_outline,
            color: Colors.redAccent, size: 20),
        _ => const SizedBox(width: 16),
      };
    }

    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: statusColor,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device.displayName,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 2),
              Text(
                isOnline ? 'Online' : 'Offline — use BLE to update',
                style: TextStyle(
                    color: isOnline ? Colors.white38 : Colors.amber,
                    fontSize: 11),
              ),
            ],
          ),
        ),
        trailing,
      ],
    );
  }
}
