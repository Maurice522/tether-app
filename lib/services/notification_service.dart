import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/transfer.dart';
import '../util/net_log.dart';

/// Local "you got something" notifications for completed transfers.
///
/// Uses the app's own launcher icon for the Android notification icon
/// rather than a new dedicated monochrome asset — a real tradeoff (Android
/// renders it as a flat white silhouette in the status bar regardless, so
/// it's serviceable, just not pixel-tuned for that treatment the way a
/// purpose-made icon would be) made to avoid standing up a whole
/// per-density image asset pipeline for this alone.
///
/// Windows support is best-effort: `flutter_local_notifications` on
/// Windows needs a correctly registered `appUserModelId`/shortcut and is
/// known to be unreliable for unpackaged dev builds. Failures there (or on
/// any platform) are logged and swallowed rather than surfaced, since a
/// missed notification shouldn't take down the transfer it's about.
class NotificationService {
  static const _channelId = 'transfers';
  static const _channelName = 'Transfers';
  static const _windowsAppUserModelId = 'com.mauricerana.tether';
  static const _windowsGuid = '5b9f6f1a-6c9b-4e5b-9c9a-7d9a2f8b6c1e';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  int _nextId = 0;

  /// Sets up the plugin and requests whatever runtime permission each
  /// platform needs. [onTapped] fires when the user taps a notification —
  /// callers don't get (or need) which transfer it was for, since tapping
  /// just jumps back to the Activity tab, same as the plan calls for.
  Future<void> init({required void Function() onTapped}) async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      macOS: DarwinInitializationSettings(),
      windows: WindowsInitializationSettings(
        appName: 'Tether',
        appUserModelId: _windowsAppUserModelId,
        guid: _windowsGuid,
      ),
    );
    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (_) => onTapped(),
      );
      if (Platform.isAndroid) {
        await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      }
    } catch (e) {
      netLog('notify', 'failed to initialize: $e');
    }
  }

  Future<void> showTransferComplete(TransferRecord record) async {
    final body = record.files.length == 1 ? record.files.first.name : '${record.files.length} files';
    try {
      await _plugin.show(
        id: _nextId++,
        title: 'Received from ${record.peerName}',
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(_channelId, _channelName, importance: Importance.defaultImportance),
          macOS: DarwinNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      netLog('notify', 'failed to show notification: $e');
    }
  }
}
