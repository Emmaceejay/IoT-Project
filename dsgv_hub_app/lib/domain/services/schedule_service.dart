import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/device_schedule.dart';
import 'device_manager.dart';

// ignore_for_file: prefer_mixin

class ScheduleState {
  final List<DeviceSchedule> schedules;

  const ScheduleState({this.schedules = const []});

  List<DeviceSchedule> forDevice(String deviceId) {
    final list =
        schedules.where((s) => s.deviceId == deviceId).toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }
}

class ScheduleNotifier extends AsyncNotifier<ScheduleState>
    with WidgetsBindingObserver {
  Timer? _timer;
  final Map<String, DateTime> _lastFired = {};

  @override
  Future<ScheduleState> build() async {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _timer?.cancel();
      WidgetsBinding.instance.removeObserver(this);
    });
    final loaded = await _load();
    _startTimer();
    return loaded;
  }

  // Re-evaluate when the app comes back from background — timers pause when
  // backgrounded so a scheduled minute can be missed entirely without this.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _evaluate();
    }
  }

  Future<void> addSchedule(DeviceSchedule schedule) async {
    final current = state.valueOrNull ?? const ScheduleState();
    final updated =
        ScheduleState(schedules: [...current.schedules, schedule]);
    state = AsyncData(updated);
    await _save(updated.schedules);
  }

  Future<void> updateSchedule(DeviceSchedule schedule) async {
    final current = state.valueOrNull ?? const ScheduleState();
    final updated = ScheduleState(
      schedules: current.schedules
          .map((s) => s.id == schedule.id ? schedule : s)
          .toList(),
    );
    state = AsyncData(updated);
    await _save(updated.schedules);
  }

  Future<void> removeSchedule(String scheduleId) async {
    final current = state.valueOrNull ?? const ScheduleState();
    final updated = ScheduleState(
      schedules:
          current.schedules.where((s) => s.id != scheduleId).toList(),
    );
    state = AsyncData(updated);
    await _save(updated.schedules);
  }

  Future<void> toggleSchedule(String scheduleId, bool enabled) async {
    final current = state.valueOrNull ?? const ScheduleState();
    final updated = ScheduleState(
      schedules: current.schedules
          .map((s) => s.id == scheduleId ? s.copyWith(enabled: enabled) : s)
          .toList(),
    );
    state = AsyncData(updated);
    await _save(updated.schedules);
  }

  void _startTimer() {
    // Delay until the next :00-second mark so every periodic tick aligns to a
    // full clock minute. Without this, Timer.periodic fires at an arbitrary
    // offset and can skip an entire scheduled minute.
    final now = DateTime.now();
    final secsUntilNext = 60 - now.second;
    _timer = Timer(Duration(seconds: secsUntilNext), () {
      _evaluate();
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => _evaluate());
    });
  }

  void _evaluate() {
    final now = DateTime.now();
    final tod = TimeOfDay.fromDateTime(now);
    final weekday = now.weekday; // 1=Mon…7=Sun

    for (final s in state.valueOrNull?.schedules ?? []) {
      if (!s.enabled) continue;
      if (s.timeHour != tod.hour || s.timeMinute != tod.minute) continue;
      if (s.days.isNotEmpty && !s.days.contains(weekday)) continue;

      final last = _lastFired[s.id];
      if (last != null && now.difference(last).inSeconds < 58) continue;

      _lastFired[s.id] = now;
      ref
          .read(deviceManagerProvider.notifier)
          .sendCommand(s.deviceId, s.command);
    }
  }

  Future<ScheduleState> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/dsgv_schedules.json');
      if (!await file.exists()) return const ScheduleState();
      final decoded =
          jsonDecode(await file.readAsString()) as List<dynamic>;
      final schedules = decoded
          .map((e) => DeviceSchedule.fromJson(e as Map<String, dynamic>))
          .toList();
      return ScheduleState(schedules: schedules);
    } catch (_) {
      return const ScheduleState();
    }
  }

  Future<void> _save(List<DeviceSchedule> schedules) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/dsgv_schedules.json');
      await file.writeAsString(
          jsonEncode(schedules.map((s) => s.toJson()).toList()));
    } catch (_) {}
  }
}

final scheduleServiceProvider =
    AsyncNotifierProvider<ScheduleNotifier, ScheduleState>(
        ScheduleNotifier.new);
