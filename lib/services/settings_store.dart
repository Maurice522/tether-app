import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persisted app identity and user preferences.
class SettingsStore {
  static const _keyDeviceId = 'device_id';
  static const _keyDeviceName = 'device_name';
  static const _keyDownloadDir = 'download_dir';
  static const _keyThemeMode = 'theme_mode'; // system | light | dark
  static const _keyClipboardSyncEnabled = 'clipboard_sync_enabled';
  static const _keyClipboardSyncDeviceId = 'clipboard_sync_device_id';
  static const _keyAskedAllFilesAccess = 'asked_all_files_access';

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
    final savedDir = prefs.getString(_keyDownloadDir);
    if (savedDir == null || _isStaleContainerPath(savedDir, defaultDownloadDir)) {
      await prefs.setString(_keyDownloadDir, defaultDownloadDir);
    }
    return store;
  }

  static const _containerMarker = '/Containers/Data/Application/';

  /// iOS gives an app a new data-container UUID whenever it's reinstalled
  /// or updated, so a download folder saved from inside the old container
  /// (`.../Application/OLD-UUID/Documents/Tether`) silently stops existing.
  /// A path inside *an* app container that isn't *this* run's container
  /// can only be such a leftover (never something the user picked), so it
  /// gets reset to the current default.
  static bool _isStaleContainerPath(String saved, String currentDefault) {
    final savedAt = saved.indexOf(_containerMarker);
    final currentAt = currentDefault.indexOf(_containerMarker);
    if (savedAt < 0 || currentAt < 0) return false;
    String containerOf(String path, int at) {
      final start = at + _containerMarker.length;
      final end = path.indexOf('/', start);
      return end < 0 ? path : path.substring(0, end);
    }
    return containerOf(saved, savedAt) != containerOf(currentDefault, currentAt);
  }

  String get deviceId => _prefs.getString(_keyDeviceId)!;

  String get deviceName => _prefs.getString(_keyDeviceName)!;
  Future<void> setDeviceName(String name) => _prefs.setString(_keyDeviceName, name);

  String get downloadDir => _prefs.getString(_keyDownloadDir)!;
  Future<void> setDownloadDir(String path) => _prefs.setString(_keyDownloadDir, path);

  /// Whether the one-time Android "All files access" prompt has been shown.
  bool get askedAllFilesAccess => _prefs.getBool(_keyAskedAllFilesAccess) ?? false;
  Future<void> setAskedAllFilesAccess() => _prefs.setBool(_keyAskedAllFilesAccess, true);

  String get themeMode => _prefs.getString(_keyThemeMode) ?? 'system';
  Future<void> setThemeMode(String mode) => _prefs.setString(_keyThemeMode, mode);

  bool get clipboardSyncEnabled => _prefs.getBool(_keyClipboardSyncEnabled) ?? false;
  Future<void> setClipboardSyncEnabled(bool enabled) => _prefs.setBool(_keyClipboardSyncEnabled, enabled);

  String? get clipboardSyncDeviceId => _prefs.getString(_keyClipboardSyncDeviceId);
  Future<void> setClipboardSyncDeviceId(String? deviceId) => deviceId == null
      ? _prefs.remove(_keyClipboardSyncDeviceId)
      : _prefs.setString(_keyClipboardSyncDeviceId, deviceId);
}
