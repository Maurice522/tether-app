import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer.dart';

/// Persists finished transfer records so history survives app restarts.
class HistoryStore {
  static const _prefsKey = 'transfer_history_v1';
  static const _maxEntries = 200;

  final SharedPreferences _prefs;

  HistoryStore._(this._prefs);

  static Future<HistoryStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    return HistoryStore._(prefs);
  }

  List<TransferRecord> readAll() {
    final raw = _prefs.getStringList(_prefsKey) ?? const [];
    final records = <TransferRecord>[];
    for (final entry in raw) {
      try {
        records.add(TransferRecord.fromJson(jsonDecode(entry) as Map<String, dynamic>));
      } catch (_) {
        // Skip corrupt entries rather than losing the whole history.
      }
    }
    return records;
  }

  Future<void> append(TransferRecord record) async {
    final existing = _prefs.getStringList(_prefsKey) ?? <String>[];
    existing.insert(0, jsonEncode(record.toJson()));
    if (existing.length > _maxEntries) {
      existing.removeRange(_maxEntries, existing.length);
    }
    await _prefs.setStringList(_prefsKey, existing);
  }

  Future<void> clear() => _prefs.remove(_prefsKey);
}
