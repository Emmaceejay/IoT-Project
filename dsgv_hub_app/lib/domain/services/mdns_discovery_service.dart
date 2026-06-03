import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multicast_dns/multicast_dns.dart';
import '../models/iot_device.dart';

/// A single device found via mDNS discovery on the local network.
/// Carries just enough information to create or update an [IoTDevice].
class MdnsResult {
  /// WiFi MAC address — e.g. "A1B2C3D4E5F6".
  /// Matches the [IoTDevice.uniqueDeviceId] and the MQTT topic prefix.
  final String deviceId;

  /// LAN IP address — e.g. "192.168.1.42".
  /// Used for direct HTTP commands (sub-10 ms latency vs MQTT).
  final String localIp;

  /// Capability list decoded from the mDNS TXT "caps" record.
  /// Same format as the MQTT announce payload, e.g. ["relay", "brightness"].
  final List<String> capabilities;

  /// Device type label — e.g. "Switch", "Dimmer". Used for display only.
  final String? deviceType;

  /// Firmware version string — e.g. "1.0.0".
  final String? firmwareVersion;

  const MdnsResult({
    required this.deviceId,
    required this.localIp,
    required this.capabilities,
    this.deviceType,
    this.firmwareVersion,
  });

  /// Converts this discovery result into an [IoTDevice] ready to be handed
  /// to [DeviceManager.handleAnnounce]. The status is set to online because
  /// we just heard from the device on the LAN.
  IoTDevice toDevice() => IoTDevice(
        uniqueDeviceId: deviceId,
        deviceName:     deviceType ?? deviceId,
        status:         DeviceStatus.online,
        capabilities:   capabilities,
        localIp:        localIp,
      );
}

/// Discovers DSGV smart devices on the local Wi-Fi network using mDNS
/// (Multicast DNS, also known as Bonjour or Avahi).
///
/// --- How mDNS discovery works ---
///
/// Normal DNS asks a server "what IP is kitchen-switch.dsgv.io?".
/// mDNS is peer-to-peer: devices on the LAN answer questions about
/// themselves by listening on the multicast address 224.0.0.251:5353.
///
/// The discovery sequence for one device looks like this:
///
///   App broadcasts  → PTR query:  "who provides _dsgv._tcp.local?"
///   Device replies  → PTR record: "DSGV Switch._dsgv._tcp.local"
///
///   App queries     → SRV record: "DSGV Switch._dsgv._tcp.local"
///   Device replies  → SRV:        target=dsgv-a1b2c3.local  port=80
///
///   App queries     → A record:   "dsgv-a1b2c3.local"
///   Device replies  → A:          192.168.1.42
///
///   App queries     → TXT record: "DSGV Switch._dsgv._tcp.local"
///   Device replies  → TXT:        id=A1B2C3 caps=["relay"] type=Switch fw=1.0.0
///
/// The [multicast_dns] Dart package handles all the socket management.
/// We just call [MDnsClient.lookup] with the record type we want.
///
/// --- When to call this ---
///
/// Call [discoverDevices] once on app start (after MQTT connect) and again
/// whenever the app resumes from background. On a typical home network
/// with 5-10 DSGV devices the full sweep completes in under 2 seconds.
class MdnsDiscoveryService {
  /// The mDNS service type that every DSGV firmware advertises.
  /// Must match MDNS_SERVICE_DSGV ("_dsgv") + MDNS_PROTO_TCP ("_tcp")
  /// in dsgv_config.h on the firmware side.
  static const _serviceType = '_dsgv._tcp';

  /// Scans the local network for DSGV devices and yields one [MdnsResult]
  /// per discovered device.
  ///
  /// The stream completes when the mDNS client times out (no more responses
  /// from the network, typically 1-3 seconds after the last device replies).
  ///
  /// Usage:
  /// ```dart
  /// await for (final result in MdnsDiscoveryService().discoverDevices()) {
  ///   await deviceManager.handleAnnounce(result.toDevice());
  /// }
  /// ```
  Stream<MdnsResult> discoverDevices() async* {
    // MDnsClient manages the multicast socket lifecycle.
    // We create a fresh client per scan to avoid stale state between calls.
    final client = MDnsClient();

    try {
      // start() opens a UDP socket bound to 0.0.0.0:5353 and joins the
      // mDNS multicast group 224.0.0.251. After this call the client is
      // ready to send queries and receive responses.
      await client.start();

      // Step 1: PTR query — ask "who provides _dsgv._tcp?"
      // Each PTR response carries the full service instance name, e.g.:
      //   "DSGV Switch._dsgv._tcp.local"
      // There will be one PTR response per DSGV device on the network.
      await for (final PtrResourceRecord ptr
          in client.lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(_serviceType))) {
        // ptr.domainName is the full service instance name.
        // We use it as the key for the subsequent SRV and TXT lookups.
        debugPrint('[mDNS] Found service: ${ptr.domainName}');

        String? localIp;
        String? deviceId;
        List<String> capabilities = [];
        String? deviceType;
        String? firmwareVersion;

        // Step 2: SRV query — resolve hostname and port for this instance.
        // SRV = "Service record". Contains: priority, weight, port, target.
        // We only care about target (hostname) and port.
        await for (final SrvResourceRecord srv
            in client.lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(ptr.domainName))) {
          debugPrint('[mDNS] SRV: ${srv.target}:${srv.port}');

          // Step 3: A record query — resolve hostname to IPv4 address.
          await for (final IPAddressResourceRecord ip
              in client.lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(srv.target))) {
            localIp = ip.address.address;
            debugPrint('[mDNS] IP resolved: $localIp');
            break; // first A record is enough
          }
          break; // first SRV record is enough
        }

        // Step 4: TXT query — read key=value metadata records.
        // The firmware advertises: id, caps, type, fw.
        // TXT record values are List<String> where each element is "key=value".
        await for (final TxtResourceRecord txt
            in client.lookup<TxtResourceRecord>(
                ResourceRecordQuery.text(ptr.domainName))) {
          for (final entry in txt.text) {
            // Split on the first '=' only — values may contain '=' themselves
            final separatorIndex = entry.indexOf('=');
            if (separatorIndex < 0) continue;
            final key   = entry.substring(0, separatorIndex);
            final value = entry.substring(separatorIndex + 1);

            switch (key) {
              case 'id':
                // MAC address in uppercase hex, e.g. "A1B2C3D4E5F6"
                deviceId = value.toUpperCase();
                break;
              case 'caps':
                // JSON array string — e.g. '["relay","brightness"]'
                // Decode it into a proper Dart list.
                try {
                  capabilities = List<String>.from(
                      jsonDecode(value) as List);
                } catch (_) {
                  // If JSON decode fails (truncated TXT), keep empty list
                  debugPrint('[mDNS] Failed to parse caps: $value');
                }
                break;
              case 'type':
                deviceType = value; // e.g. "Switch", "Dimmer"
                break;
              case 'fw':
                firmwareVersion = value; // e.g. "1.0.0"
                break;
            }
          }
          break; // first TXT record set is enough
        }

        // Only emit a result if we got at minimum an IP and a device ID.
        // Missing TXT records are non-fatal — the device will fill in
        // capabilities when its MQTT announce arrives shortly after.
        if (localIp != null && deviceId != null) {
          yield MdnsResult(
            deviceId:        deviceId,
            localIp:         localIp,
            capabilities:    capabilities,
            deviceType:      deviceType,
            firmwareVersion: firmwareVersion,
          );
        } else {
          debugPrint(
              '[mDNS] Incomplete record for ${ptr.domainName} — '
              'ip=$localIp id=$deviceId — skipping.');
        }
      }
    } catch (e) {
      // mDNS is a best-effort mechanism. Log and swallow errors so the
      // rest of the app (MQTT, HTTP) continues working unaffected.
      debugPrint('[mDNS] Discovery error: $e');
    } finally {
      // Always stop the client to close the socket and leave the multicast group.
      // Forgetting this leaks a socket descriptor on Android.
      client.stop();
    }
  }
}

/// Global Riverpod provider for the mDNS discovery service.
/// Exposed as a Provider (not StateNotifier) because the service is
/// stateless — each [discoverDevices] call is a fresh scan.
final mdnsDiscoveryServiceProvider = Provider<MdnsDiscoveryService>((ref) {
  return MdnsDiscoveryService();
});
