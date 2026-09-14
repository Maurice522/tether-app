import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Picks a sensible default "downloads" folder per platform.
///
/// Desktop platforms have a real Downloads directory. Android has no
/// stable equivalent reachable without extra storage permissions, so we
/// use an app-owned folder under external storage instead; it's still
/// easy for the user to find via a file manager and needs no runtime
/// permission grant on modern Android.
Future<String> defaultDownloadDir() async {
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    final dir = await getDownloadsDirectory();
    if (dir != null) return dir.path;
  }
  if (Platform.isAndroid) {
    final dirs = await getExternalStorageDirectories();
    if (dirs != null && dirs.isNotEmpty) {
      final path = p.join(dirs.first.path, 'LanShare');
      await Directory(path).create(recursive: true);
      return path;
    }
  }
  final fallback = await getApplicationDocumentsDirectory();
  final path = p.join(fallback.path, 'LanShare');
  await Directory(path).create(recursive: true);
  return path;
}

/// Returns a path under [dir] for [fileName] that doesn't clobber an
/// existing file, appending " (1)", " (2)", etc. before the extension.
Future<String> uniqueSavePath(String dir, String fileName) async {
  final ext = p.extension(fileName);
  final base = p.basenameWithoutExtension(fileName);
  var candidate = p.join(dir, fileName);
  var attempt = 1;
  while (await File(candidate).exists()) {
    candidate = p.join(dir, '$base ($attempt)$ext');
    attempt++;
  }
  return candidate;
}
