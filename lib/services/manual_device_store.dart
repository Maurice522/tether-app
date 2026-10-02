import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../util/net_log.dart';

/// Persists devices successfully added via "Add device by IP" so the next
/// session doesn't need the IP retyped — the whole point of this fallback
/// is to be fast once a peer's address is known, not just a one-off.
class ManualDeviceStore {
  static const _prefsKey = 'manual_devices_v1';

  final SharedPreferences _prefs;
  final Map<String, Map<String, dynamic>> _entries = {}; // id -> {name, platform, address, port}

  ManualDeviceStore._(this._prefs);

  static Future<ManualDeviceStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = ManualDeviceStore._(prefs);
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        store._entries.addAll(map.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map))));
      } catch (e) {
        // Corrupt/old data; start fresh rather than fail to load, but log
        // it — silently forgetting every manually-added device is
        // surprising enough that it should leave a diagnostic trace.
        netLog('manual', 'failed to load manual devices, resetting: $e');
      }
    }
    return store;
  }

  /// Most-recently-added first.
  List<Device> get all => _entries.entries
      .map((e) => Device(
            id: e.key,
            name: e.value['name'] as String,
            platform: e.value['platform'] as String,
            address: e.value['address'] as String,
            port: e.value['port'] as int,
            lastSeen: DateTime.now(),
          ))
      .toList()
      .reversed
      .toList();

  Future<void> remember(Device device) async {
    // Re-insert at the end so `all` (reversed) surfaces it first.
    _entries.remove(device.id);
    _entries[device.id] = {
      'name': device.name,
      'platform': device.platform,
      'address': device.address,
      'port': device.port,
    };
    await _persist();
  }

  Future<void> forget(String id) async {
    _entries.remove(id);
    await _persist();
  }

  Future<void> _persist() => _prefs.setString(_prefsKey, jsonEncode(_entries));
}
