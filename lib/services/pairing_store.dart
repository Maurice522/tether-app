import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists which peer device ids the user has explicitly paired with.
///
/// A paired device skips the pairing code *and* the accept/decline prompt
/// entirely on every future transfer, in both directions — pairing is the
/// one deliberate step; everything after it is prompt-free.
class PairingStore {
  static const _prefsKey = 'trusted_devices_v1';

  final SharedPreferences _prefs;
  final Map<String, String> _trusted = {}; // deviceId -> last known name

  PairingStore._(this._prefs);

  static Future<PairingStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = PairingStore._(prefs);
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        store._trusted.addAll(map.map((k, v) => MapEntry(k, v as String)));
      } catch (_) {
        // Corrupt/old data; start fresh.
      }
    }
    return store;
  }

  bool isTrusted(String deviceId) => _trusted.containsKey(deviceId);

  List<String> get trustedIds => _trusted.keys.toList(growable: false);

  String? nameFor(String deviceId) => _trusted[deviceId];

  Future<void> trust(String deviceId, String name) async {
    _trusted[deviceId] = name;
    await _persist();
  }

  Future<void> untrust(String deviceId) async {
    _trusted.remove(deviceId);
    await _persist();
  }

  Future<void> _persist() => _prefs.setString(_prefsKey, jsonEncode(_trusted));
}
