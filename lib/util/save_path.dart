import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// The phone's public Downloads folder. Reading/listing it (as Browse
/// needs, and as sharing it with paired devices means) takes Android's
/// "All files access", since scoped storage hides everything in it that
/// this app didn't create itself.
const androidPublicDownloadsDir = '/storage/emulated/0/Download';

/// Whether [path] is inside an app-private Android directory (the
/// fallback used when "All files access" isn't granted).
bool isAppPrivateAndroidPath(String path) => path.contains('/Android/data/');

Future<bool> androidHasAllFilesAccess() async => Platform.isAndroid && await Permission.manageExternalStorage.isGranted;

/// Sends the user to Android's "All files access" screen for this app and
/// resolves once they're back, with whether it ended up granted.
Future<bool> androidRequestAllFilesAccess() async =>
    Platform.isAndroid && (await Permission.manageExternalStorage.request()).isGranted;

/// The app-owned external folder — always usable with no permission.
Future<String?> androidPrivateDownloadDir() async {
  final dirs = await getExternalStorageDirectories();
  if (dirs == null || dirs.isEmpty) return null;
  final path = p.join(dirs.first.path, 'Tether');
  await Directory(path).create(recursive: true);
  return path;
}

/// Picks a sensible default "downloads" folder per platform.
///
/// Desktop platforms have a real Downloads directory. On Android that's
/// the public Downloads folder when "All files access" has been granted,
/// otherwise an app-owned folder under external storage (reachable with
/// no permission, though invisible to other apps).
Future<String> defaultDownloadDir() async {
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    final dir = await getDownloadsDirectory();
    if (dir != null) return dir.path;
  }
  if (Platform.isAndroid) {
    if (await androidHasAllFilesAccess() && await Directory(androidPublicDownloadsDir).exists()) {
      return androidPublicDownloadsDir;
    }
    final private = await androidPrivateDownloadDir();
    if (private != null) return private;
  }
  final fallback = await getApplicationDocumentsDirectory();
  final path = p.join(fallback.path, 'Tether');
  await Directory(path).create(recursive: true);
  return path;
}

/// Paths this process has already handed out via [uniqueSavePath] but
/// that may not exist on disk yet (the caller opens the file right after,
/// but hasn't necessarily written to it the instant this returns). Two
/// incoming transfers racing on the same filename would otherwise both
/// see "doesn't exist yet" and collide on the same candidate — tracked
/// for the app's lifetime rather than removed once written, since that's
/// exactly the same "already spoken for" answer a fresh disk check would
/// give once the file actually appears.
final _reservedPaths = <String>{};

/// Returns a path under [dir] for [fileName] that doesn't clobber an
/// existing file, appending " (1)", " (2)", etc. before the extension.
Future<String> uniqueSavePath(String dir, String fileName) async {
  final ext = p.extension(fileName);
  final base = p.basenameWithoutExtension(fileName);
  var candidate = p.join(dir, fileName);
  var attempt = 1;
  while (_reservedPaths.contains(candidate) || await File(candidate).exists()) {
    candidate = p.join(dir, '$base ($attempt)$ext');
    attempt++;
  }
  _reservedPaths.add(candidate);
  return candidate;
}
