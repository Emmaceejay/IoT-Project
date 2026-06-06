import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/objectbox_store_provider.dart';
import '../../data/datasources/objectbox_device_datasource.dart';
import '../../data/repositories/device_repository.dart';
import '../models/matter_device.dart';
import 'firebase_config_service.dart';
import 'local_http_service.dart';
import 'mqtt_service.dart';
import 'telemetry_service.dart';

/// Production device repository — ObjectBox-backed, offline-first.
///
/// Architecture whitepaper §4: "The user interface interacts exclusively with
/// a local database cache. Pressing a UI switch instantly mutates the cache,
/// making the app feel zero-latency."
///
/// Swap this provider to [MockDeviceDatasource] for isolated UI development
/// without a running broker or real hardware.
final deviceRepositoryProvider = Provider<DeviceRepository>((ref) {
  final store = ref.watch(objectboxStoreProvider);
  return ObjectBoxDeviceDatasource(store);
});

/// The reactive state engine for all IoT devices.
///
/// Command routing priority (architecture whitepaper §3 — Hybrid Dual-Broker):
///   1. Local HTTP    — if device has [localIp] and phone is on WiFi
///   2. MQTT          — cloud or local broker
///   3. ObjectBox DB  — optimistic update always applied first
class DeviceManager extends AsyncNotifier<List<MatterDevice>> {
  late DeviceRepository _repository;

  // Holds tokens received from BLE provisioning until the device's MQTT
  // announce message arrives and confirms the device_id (WiFi MAC).
  final _pendingTokens = <String, String>{};

  @override
  Future<List<MatterDevice>> build() async {
    _repository = ref.watch(deviceRepositoryProvider);
    return _repository.getDevices();
  }

  /// Stores an auth token received over BLE for a just-provisioned device.
  /// The token is matched to the device when its MQTT announce arrives.
  void setPendingToken(String deviceId, String token) {
    _pendingTokens[deviceId.toUpperCase()] = token;
    debugPrint('[DeviceManager] Pending token stored for $deviceId');
  }

  /// Refreshes the full device list from the Isar cache.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _repository.getDevices());
  }

  /// Sends a state-change command for [deviceId].
  ///
  /// 1. Optimistic UI update (instant, zero-latency)
  /// 2. Local HTTP transport (if on same WiFi and device has IP)
  /// 3. MQTT (cloud or local broker fallback)
  /// 4. Isar persistence
  Future<void> sendCommand(String deviceId, Map<String, dynamic> command) async {
    // Optimistic update — UI reacts instantly before any network round-trip
    state = AsyncValue.data(
      (state.valueOrNull ?? []).map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(telemetry: {...d.telemetry, ...command});
      }).toList(),
    );

    final device = state.value?.firstWhere(
      (d) => d.uniqueDeviceId == deviceId,
      orElse: () => MatterDevice(uniqueDeviceId: deviceId, deviceName: ''),
    );

    // 1. Local HTTP — preferred transport when on same LAN
    final localIp = device?.localIp;
    if (localIp != null && localIp.isNotEmpty) {
      final httpService = ref.read(localHttpServiceProvider);
      if (await httpService.isOnWifi()) {
        bool allDelivered = true;
        for (final entry in command.entries) {
          final ok = await httpService.sendCommand(
              localIp, entry.key, entry.value);
          if (!ok) {
            allDelivered = false;
            break;
          }
        }
        if (allDelivered) {
          await _repository.updateDeviceState(deviceId, command);
          return;
        }
        debugPrint('[DeviceManager] HTTP failed — falling back to MQTT.');
        ref.read(telemetryServiceProvider).logCommandDropped(
            deviceId, 'local_http_failed');
      }
    }

    // 2. MQTT transport
    final mqttStatus = ref.read(mqttServiceProvider);
    if (mqttStatus.isConnected) {
      final payload = jsonEncode({'device_id': deviceId, ...command});
      await ref.read(mqttServiceProvider.notifier).publishCommand(deviceId, payload);
    } else {
      ref.read(telemetryServiceProvider).logCommandDropped(
          deviceId, 'no_transport_available');
    }

    // 3. Persist to ObjectBox cache
    await _repository.updateDeviceState(deviceId, command);
  }

  /// Persists a user-chosen display name for [deviceId].
  /// Pass empty string to revert to the auto-generated firmware name.
  Future<void> renameDevice(String deviceId, String newName) async {
    await _repository.renameDevice(deviceId, newName);
    final trimmed = newName.trim().isEmpty ? null : newName.trim();
    state = AsyncValue.data(
      (state.valueOrNull ?? []).map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(customName: trimmed);
      }).toList(),
    );
    debugPrint('[DeviceManager] Device $deviceId renamed to "${trimmed ?? "<auto>"}"');
  }

  /// Removes a device from the local registry and live state.
  Future<void> removeDevice(String deviceId) async {
    await _repository.removeDevice(deviceId);
    state = AsyncValue.data(
      (state.valueOrNull ?? [])
          .where((d) => d.uniqueDeviceId != deviceId)
          .toList(),
    );
    debugPrint('[DeviceManager] Device $deviceId removed.');
  }

  /// Registers a newly commissioned device (called after Matter pairing).
  Future<void> registerNewDevice(MatterDevice device) async {
    await _repository.provisionDevice(device);
    ref.read(telemetryServiceProvider).logProvisionResult(
        device.uniqueDeviceId, success: true);
    await refresh();
  }

  /// Marks a device as online — triggered by MQTT status="online" messages.
  Future<void> markDeviceOnline(String deviceId) async {
    state = AsyncValue.data(
      (state.valueOrNull ?? []).map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(status: DeviceStatus.online);
      }).toList(),
    );
    await _repository.updateDeviceStatus(deviceId, DeviceStatus.online);
    debugPrint('[DeviceManager] Device $deviceId is online.');
  }

  /// Marks a device as offline — triggered by MQTT LWT messages.
  Future<void> markDeviceOffline(String deviceId) async {
    state = AsyncValue.data(
      (state.valueOrNull ?? []).map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(status: DeviceStatus.offline);
      }).toList(),
    );
    await _repository.updateDeviceStatus(deviceId, DeviceStatus.offline);
    debugPrint('[DeviceManager] Device $deviceId went offline (LWT).');
  }

  /// Applies live telemetry payload from MQTT to the matching device.
  /// If the payload contains [power_restore], it is extracted and stored as a
  /// dedicated field rather than mixed into the raw telemetry map.
  void applyTelemetry(String deviceId, Map<String, dynamic> telemetry) {
    final devices = state.value;
    if (devices == null) return;

    // Extract power_restore before storing telemetry so it stays a typed field.
    final restoreRaw = telemetry['power_restore'] as String?;
    PowerRestoreMode? restoreMode;
    if (restoreRaw != null) {
      restoreMode = PowerRestoreMode.values.firstWhere(
        (m) => m.name == restoreRaw,
        orElse: () => PowerRestoreMode.off,
      );
    }
    final cleanTelemetry = restoreRaw != null
        ? (Map<String, dynamic>.from(telemetry)..remove('power_restore'))
        : telemetry;

    state = AsyncValue.data(
      devices.map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(
          status: DeviceStatus.online,
          telemetry: {...d.telemetry, ...cleanTelemetry},
          powerRestoreMode: restoreMode,
        );
      }).toList(),
    );
    _repository.updateDeviceState(deviceId, cleanTelemetry);
    if (restoreMode != null) {
      _repository.updatePowerRestoreMode(deviceId, restoreMode);
    }
  }

  /// Sends the user's power restore preference to the device and persists it.
  /// The command is sent via MQTT. Local state and ObjectBox are updated
  /// optimistically so the UI reflects the change even while the device is
  /// processing the request.
  Future<void> setPowerRestoreMode(
      String deviceId, PowerRestoreMode mode) async {
    // 1. Optimistic local update
    state = AsyncValue.data(
      (state.valueOrNull ?? []).map((d) {
        if (d.uniqueDeviceId != deviceId) return d;
        return d.copyWith(powerRestoreMode: mode);
      }).toList(),
    );

    // 2. MQTT command — device stores it in NVS and echoes back in telemetry
    final mqttStatus = ref.read(mqttServiceProvider);
    if (mqttStatus.isConnected) {
      final payload =
          jsonEncode({'device_id': deviceId, 'power_restore': mode.name});
      await ref
          .read(mqttServiceProvider.notifier)
          .publishCommand(deviceId, payload);
    }

    // 3. Persist to ObjectBox
    await _repository.updatePowerRestoreMode(deviceId, mode);
    debugPrint('[DeviceManager] Device $deviceId power_restore → ${mode.name}');
  }

  /// Handles a device announce message from MQTT.
  /// Registers unknown devices or updates [localIp] for known ones.
  /// Attaches a pending auth token if this is a just-provisioned device.
  Future<void> handleAnnounce(MatterDevice announced) async {
    final devices = state.value ?? [];
    final normalised = announced.uniqueDeviceId.toUpperCase();
    final pendingToken = _pendingTokens.remove(normalised);

    // Merge token: prefer pending (freshly provisioned) over existing stored value
    final resolvedToken = pendingToken ??
        devices.where((d) => d.uniqueDeviceId == normalised)
            .map((d) => d.authToken)
            .firstOrNull;

    final withToken = pendingToken != null
        ? announced.copyWith(authToken: pendingToken)
        : announced;

    final existingIndex =
        devices.indexWhere((d) => d.uniqueDeviceId == normalised);

    if (existingIndex == -1) {
      await _repository.provisionDevice(withToken);
      state = AsyncValue.data([...devices, withToken]);
    } else {
      // Preserve the user-set custom name — MQTT announce must never wipe it.
      final existingCustomName = devices[existingIndex].customName;

      state = AsyncValue.data(
        devices.map((d) {
          if (d.uniqueDeviceId != normalised) return d;
          // Do NOT set status here. The devices/{id}/status topic is the sole
          // authority for online/offline to prevent a retained announce message
          // from overriding a retained LWT offline message on reconnect.
          return d.copyWith(
            localIp: announced.localIp ?? d.localIp,
            capabilities: announced.capabilities.isNotEmpty
                ? announced.capabilities
                : d.capabilities,
            authToken: resolvedToken ?? d.authToken,
            // customName left unchanged — copyWith sentinel keeps existing value
          );
        }).toList(),
      );
      await _repository.provisionDevice(
        withToken.copyWith(
          localIp: announced.localIp,
          authToken: resolvedToken,
          customName: existingCustomName, // explicitly carry forward
        ),
      );
    }
  }

  /// Registers a newly provisioned device in Firebase.
  /// Called immediately after BLE provisioning succeeds so the device
  /// gets a config entry before its first HTTPS fetch on boot.
  Future<void> registerDevice(String deviceId, String authToken) async {
    await ref.read(firebaseConfigServiceProvider).registerDevice(
      deviceId: deviceId,
      authToken: authToken,
    );
    debugPrint('[DeviceManager] Firebase registration triggered for $deviceId');
  }

  /// Writes the current custom broker config to Firebase for every provisioned
  /// device. Devices pick it up on their next reboot or config poll.
  ///
  /// Returns the number of devices updated.
  Future<int> pushBrokerConfig() async {
    final devices = state.valueOrNull ?? [];
    final config  = ref.read(mqttConfigProvider);
    final firebase = ref.read(firebaseConfigServiceProvider);

    int sent = 0;
    for (final device in devices) {
      if (device.authToken == null) continue;
      final ok = await firebase.updateDeviceConfig(
        deviceId:  device.uniqueDeviceId,
        authToken: device.authToken!,
        config:    config,
      );
      if (ok) {
        sent++;
        debugPrint('[DeviceManager] Firebase config updated for ${device.uniqueDeviceId}');
      }
    }
    return sent;
  }

  /// Resets a single device's broker config to the factory default in Firebase.
  Future<void> revertDeviceBroker(String deviceId, String authToken) async {
    await ref.read(firebaseConfigServiceProvider).revertDeviceToFactory(
      deviceId:  deviceId,
      authToken: authToken,
    );
    debugPrint('[DeviceManager] Firebase factory revert triggered for $deviceId');
  }
}

/// The global provider — all dashboard widgets watch this.
final deviceManagerProvider =
    AsyncNotifierProvider<DeviceManager, List<MatterDevice>>(DeviceManager.new);
