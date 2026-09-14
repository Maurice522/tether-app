import 'dart:io';

import 'package:path/path.dart' as p;

/// Opens [path] (a directory) in the platform's file manager.
Future<void> openFolder(String path) async {
  if (Platform.isMacOS) {
    await Process.run('open', [path]);
  } else if (Platform.isWindows) {
    await Process.run('explorer', [path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [path]);
  }
}

/// Opens the file manager with [filePath] selected/highlighted, falling
/// back to just opening its containing folder where that isn't supported.
Future<void> revealFile(String filePath) async {
  if (Platform.isMacOS) {
    await Process.run('open', ['-R', filePath]);
  } else if (Platform.isWindows) {
    await Process.run('explorer', ['/select,$filePath']);
  } else {
    await openFolder(p.dirname(filePath));
  }
}
