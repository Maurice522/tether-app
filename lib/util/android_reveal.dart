import 'package:flutter/services.dart';

const _revealChannel = MethodChannel('com.mauricerana.tether/reveal');

/// Hands [path] to whatever app Android considers the right viewer for it
/// (same behavior as tapping a completed download's notification) via a
/// content:// URI, since a raw file path can't be shared with another app
/// under scoped storage. Returns whether an app was found to handle it.
Future<bool> androidOpenFile(String path) async {
  final ok = await _revealChannel.invokeMethod<bool>('openFile', {'path': path});
  return ok ?? false;
}

/// Best-effort "open this folder" — Android has no reliable equivalent of
/// Finder/Explorer's folder view for an arbitrary filesystem path, so this
/// may fail even when [androidOpenFile] would succeed for a file inside it.
Future<bool> androidOpenFolder(String path) async {
  final ok = await _revealChannel.invokeMethod<bool>('openFolder', {'path': path});
  return ok ?? false;
}

/// Copies the file at [path] into the public MediaStore Downloads
/// collection (as "Downloads/Tether/[fileName]") so it shows up in the
/// Files app and other apps' pickers — needs no runtime permission on
/// modern Android, unlike broad storage access. Purely additive: [path]
/// (the app's own folder, what Browse/resume actually read from) stays
/// the source of truth regardless of whether this succeeds.
Future<bool> androidPublishToDownloads(String path, String fileName) async {
  final ok = await _revealChannel.invokeMethod<bool>('publishToDownloads', {'path': path, 'fileName': fileName});
  return ok ?? false;
}
