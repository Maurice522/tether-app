import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persisted app identity and user preferences.
class SettingsStore {
  static const _keyDeviceId = 'device_id';
  static const _keyDeviceName = 'device_name';
  static const _keyDownloadDir = 'download_dir';
  static const _keyThemeMode = 'theme_mode'; // system | light | dark

  final SharedPreferences _prefs;

  SettingsStore._(this._prefs);

  static Future<SettingsStore> load({required String defaultName, required String defaultDownloadDir}) async {
    final prefs = await SharedPreferences.getInstance();
    final store = SettingsStore._(prefs);
    if (!prefs.containsKey(_keyDeviceId)) {
      await prefs.setString(_keyDeviceId, const Uuid().v4());
    }
    if (!prefs.containsKey(_keyDeviceName)) {
      await prefs.setString(_keyDeviceName, defaultName);
    }
    if (!prefs.containsKey(_keyDownloadDir)) {
      await prefs.setString(_keyDownloadDir, defaultDownloadDir);
    }
    return store;
  }

  String get deviceId => _prefs.getString(_keyDeviceId)!;

  String get deviceName => _prefs.getString(_keyDeviceName)!;
  Future<void> setDeviceName(String name) => _prefs.setString(_keyDeviceName, name);

  String get downloadDir => _prefs.getString(_keyDownloadDir)!;
  Future<void> setDownloadDir(String path) => _prefs.setString(_keyDownloadDir, path);

  String get themeMode => _prefs.getString(_keyThemeMode) ?? 'system';
  Future<void> setThemeMode(String mode) => _prefs.setString(_keyThemeMode, mode);
}
