import 'dart:io';

import 'package:path/path.dart' as p;

import 'android_reveal.dart';

/// Opens [path] (a directory) in the platform's file manager. Returns
/// whether that's likely to have worked, so callers can tell the user
/// when it silently couldn't (e.g. no app on Android willing to browse an
/// arbitrary folder) instead of nothing visibly happening.
Future<bool> openFolder(String path) async {
  if (Platform.isMacOS) {
    await Process.run('open', [path]);
    return true;
  } else if (Platform.isWindows) {
    await Process.run('explorer', [path]);
    return true;
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [path]);
    return true;
  } else if (Platform.isAndroid) {
    return androidOpenFolder(path);
  }
  return false;
}

/// Opens the file manager with [filePath] selected/highlighted, falling
/// back to just opening its containing folder where that isn't supported.
/// Android has no such concept — there, this opens the file directly with
/// whatever app the OS considers the right viewer for it, the same as
/// tapping a completed download's notification.
Future<bool> revealFile(String filePath) async {
  if (Platform.isMacOS) {
    await Process.run('open', ['-R', filePath]);
    return true;
  } else if (Platform.isWindows) {
    await Process.run('explorer', ['/select,$filePath']);
    return true;
  } else if (Platform.isAndroid) {
    return androidOpenFile(filePath);
  } else {
    return openFolder(p.dirname(filePath));
  }
}
