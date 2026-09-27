import 'package:flutter/services.dart';

const _quitChannel = MethodChannel('com.mauricerana.lan_share/quit');

/// Tells the native side to stop the foreground service and terminate
/// the process. Only meaningful on Android — the foreground service that
/// keeps the app alive in the background only exists there, so this is
/// what an explicit "Quit" needs to undo. Call after the Dart-side
/// network services are already stopped, so peers see a clean
/// disconnect rather than the process just vanishing mid-request.
Future<void> quitAndroidApp() => _quitChannel.invokeMethod('quit');
