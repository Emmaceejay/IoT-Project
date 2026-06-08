import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../models/room.dart';

/// Combined state of rooms and device-to-room assignments.
class RoomState {
  final List<Room> rooms;

  /// Maps deviceId (uppercase) → roomId.
  final Map<String, String> assignments;

  const RoomState({
    this.rooms = const [],
    this.assignments = const {},
  });

  String? roomIdForDevice(String deviceId) =>
      assignments[deviceId.toUpperCase()];

  Room? roomForDevice(String deviceId) {
    final id = roomIdForDevice(deviceId);
    if (id == null) return null;
    return rooms.where((r) => r.id == id).firstOrNull;
  }
}

/// Persists rooms and device assignments to JSON files in the app documents dir.
/// No ObjectBox entity needed — rooms are a small, app-level concern.
class RoomNotifier extends AsyncNotifier<RoomState> {
  @override
  Future<RoomState> build() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final roomsFile = File('${dir.path}/dsgv_rooms.json');
      final assignFile = File('${dir.path}/dsgv_device_rooms.json');

      List<Room> rooms = [];
      Map<String, String> assignments = {};

      if (await roomsFile.exists()) {
        final decoded =
            jsonDecode(await roomsFile.readAsString()) as List<dynamic>;
        rooms = decoded
            .map((e) => Room.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      if (await assignFile.exists()) {
        final decoded = jsonDecode(await assignFile.readAsString())
            as Map<String, dynamic>;
        assignments = decoded.cast<String, String>();
      }

      return RoomState(rooms: rooms, assignments: assignments);
    } catch (_) {
      return const RoomState();
    }
  }

  Future<void> addRoom(Room room) async {
    final current = state.valueOrNull ?? const RoomState();
    final updated = RoomState(
      rooms: [...current.rooms, room],
      assignments: current.assignments,
    );
    state = AsyncData(updated);
    await _saveRooms(updated.rooms);
  }

  Future<void> removeRoom(String roomId) async {
    final current = state.valueOrNull ?? const RoomState();
    final assignments = Map<String, String>.from(current.assignments)
      ..removeWhere((_, v) => v == roomId);
    final updated = RoomState(
      rooms: current.rooms.where((r) => r.id != roomId).toList(),
      assignments: assignments,
    );
    state = AsyncData(updated);
    await _saveRooms(updated.rooms);
    await _saveAssignments(assignments);
  }

  Future<void> updateRoom(Room room) async {
    final current = state.valueOrNull ?? const RoomState();
    final updated = RoomState(
      rooms: current.rooms.map((r) => r.id == room.id ? room : r).toList(),
      assignments: current.assignments,
    );
    state = AsyncData(updated);
    await _saveRooms(updated.rooms);
  }

  /// Assigns [deviceId] to [roomId], or removes the assignment when [roomId] is null.
  Future<void> assignDevice(String deviceId, String? roomId) async {
    final current = state.valueOrNull ?? const RoomState();
    final assignments = Map<String, String>.from(current.assignments);
    final key = deviceId.toUpperCase();
    if (roomId == null) {
      assignments.remove(key);
    } else {
      assignments[key] = roomId;
    }
    state = AsyncData(RoomState(rooms: current.rooms, assignments: assignments));
    await _saveAssignments(assignments);
  }

  Future<void> _saveRooms(List<Room> rooms) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/dsgv_rooms.json');
      await file.writeAsString(
          jsonEncode(rooms.map((r) => r.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> _saveAssignments(Map<String, String> assignments) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/dsgv_device_rooms.json');
      await file.writeAsString(jsonEncode(assignments));
    } catch (_) {}
  }
}

final roomServiceProvider =
    AsyncNotifierProvider<RoomNotifier, RoomState>(RoomNotifier.new);
