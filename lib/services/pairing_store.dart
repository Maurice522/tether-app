import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../util/net_log.dart';

/// A paired device: its last-known display name, and the TLS certificate
/// fingerprint pinned for it. [certFingerprint] is null for a device
/// trusted before TLS existed (migrated from the old schema) or, briefly,
/// between trusting a device and its first successful connection —
/// treated as "pin on next connect" (trust-on-first-use) rather than
/// forcing every existing pair to redo pairing after this upgrade.
///
/// [pairedAt] is when trust was last granted (null for entries saved
/// before it existed, which are simply treated as long-established). Trust
/// reconciliation uses it as a grace period: the two sides of a pairing
/// never commit at exactly the same instant, so a peer that looks
/// momentarily unaware of a brand-new pairing isn't evidence of removal.
class TrustedDevice {
  final String name;
  final String? certFingerprint;
  final DateTime? pairedAt;

  const TrustedDevice({required this.name, this.certFingerprint, this.pairedAt});

  Map<String, dynamic> toJson() =>
      {'name': name, 'certFingerprint': certFingerprint, 'pairedAt': pairedAt?.millisecondsSinceEpoch};

  factory TrustedDevice.fromJson(Map<String, dynamic> json) {
    final at = json['pairedAt'] as int?;
    return TrustedDevice(
      name: json['name'] as String,
      certFingerprint: json['certFingerprint'] as String?,
      pairedAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// Persists which peer device ids the user has explicitly paired with.
///
/// A paired device skips the pairing code *and* the accept/decline prompt
/// entirely on every future transfer, in both directions — pairing is the
/// one deliberate step; everything after it is prompt-free.
class PairingStore {
  static const _prefsKey = 'trusted_devices_v2';
  static const _legacyPrefsKey = 'trusted_devices_v1';

  final SharedPreferences _prefs;
  final Map<String, TrustedDevice> _trusted = {};

  PairingStore._(this._prefs);

  static Future<PairingStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = PairingStore._(prefs);
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        store._trusted.addAll(map.map((k, v) => MapEntry(k, TrustedDevice.fromJson(v as Map<String, dynamic>))));
      } catch (e) {
        // Corrupt/incompatible data; start fresh rather than fail to load,
        // but log it — silently forgetting every paired device is
        // surprising enough that it should leave a diagnostic trace.
        netLog('pairing', 'failed to load trusted devices, resetting: $e');
      }
    } else {
      // First run after the TLS upgrade: carry forward pre-existing trust
      // from the old schema instead of forcing everyone to re-pair. Each
      // migrated device starts with no pinned fingerprint — it's pinned on
      // its first connection since (trust-on-first-use), a deliberate
      // one-time-window tradeoff over blanket forced re-pairing.
      final legacyRaw = prefs.getString(_legacyPrefsKey);
      if (legacyRaw != null) {
        try {
          final map = jsonDecode(legacyRaw) as Map<String, dynamic>;
          store._trusted.addAll(map.map((k, v) => MapEntry(k, TrustedDevice(name: v as String))));
          netLog('pairing', 'migrated ${store._trusted.length} trusted device(s) from v1, fingerprint pin pending');
          await store._persist();
        } catch (e) {
          netLog('pairing', 'failed to migrate v1 trusted devices: $e');
        }
      }
    }
    return store;
  }

  bool isTrusted(String deviceId) => _trusted.containsKey(deviceId);

  List<String> get trustedIds => _trusted.keys.toList(growable: false);

  String? nameFor(String deviceId) => _trusted[deviceId]?.name;

  /// The pinned certificate fingerprint for [deviceId], or null if it
  /// isn't trusted yet, or is trusted but hasn't completed a connection
  /// since being trusted/migrated (in which case the next connection's
  /// certificate is accepted and pinned, whatever it is).
  String? expectedFingerprint(String deviceId) => _trusted[deviceId]?.certFingerprint;

  /// When [deviceId] was last (re-)trusted, or null if it isn't trusted or
  /// predates this being recorded.
  DateTime? pairedAt(String deviceId) => _trusted[deviceId]?.pairedAt;

  Future<void> trust(String deviceId, String name) async {
    // Preserve an already-pinned fingerprint if this device is somehow
    // trusted a second time (e.g. re-pairing) rather than resetting it.
    // [pairedAt] always restarts though: a re-pair is a fresh pairing
    // event whose other half is about to land, so it gets its own grace.
    _trusted[deviceId] = TrustedDevice(
      name: name,
      certFingerprint: _trusted[deviceId]?.certFingerprint,
      pairedAt: DateTime.now(),
    );
    await _persist();
  }

  /// Pins [fingerprint] for [deviceId] — called once a connection to it has
  /// been made. A no-op if the device isn't trusted, since pinning implies
  /// trust rather than granting it.
  Future<void> pinFingerprint(String deviceId, String fingerprint) async {
    final existing = _trusted[deviceId];
    if (existing == null || fingerprint.isEmpty) return;
    _trusted[deviceId] =
        TrustedDevice(name: existing.name, certFingerprint: fingerprint, pairedAt: existing.pairedAt);
    await _persist();
  }

  Future<void> untrust(String deviceId) async {
    _trusted.remove(deviceId);
    await _persist();
  }

  Future<void> _persist() => _prefs.setString(_prefsKey, jsonEncode(_trusted.map((k, v) => MapEntry(k, v.toJson()))));
}
