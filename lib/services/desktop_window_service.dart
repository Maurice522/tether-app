import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps the app alive in the background on desktop platforms: closing the
/// window hides it instead of quitting the process, and a tray icon lets
/// the user reopen the window or actually quit. No-op on mobile, where the
/// OS already owns this lifecycle.
class DesktopWindowService with WindowListener, TrayListener {
  static bool get isSupported => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  bool _initialized = false;

  Future<void> init() async {
    if (!isSupported || _initialized) return;
    _initialized = true;

    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);

      trayManager.addListener(this);
      await trayManager.setIcon(Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png');
      await trayManager.setToolTip('Tether');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Show Tether', onClick: (_) => bringToFront()),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit', onClick: (_) => _quit()),
      ]));
    } catch (e) {
      // Background/tray support is a nice-to-have on top of a working app —
      // never let a platform hiccup here block startup.
      // ignore: avoid_print
      print('[DesktopWindowService] init failed: $e');
    }
  }

  Future<void> bringToFront() async {
    if (!isSupported) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void onWindowClose() async {
    final preventClose = await windowManager.isPreventClose();
    if (preventClose) {
      await windowManager.hide();
    }
  }

  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }
}
