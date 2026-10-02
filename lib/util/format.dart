import 'package:flutter/material.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  var unitIndex = -1;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final decimals = value < 10 ? 1 : 0;
  // Rounding for display can push the value up to the next unit's
  // threshold (e.g. 1023.96 KB rounds to "1024 KB" instead of promoting
  // to "1.0 MB") — check after rounding and bump once more when that
  // happens, rather than only checking the unrounded value.
  if (double.parse(value.toStringAsFixed(decimals)) >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unitIndex]}';
}

/// A short "Xm Ys" / "Ys" readout for an ETA — not a full HH:MM:SS clock,
/// since transfers here are never expected to run past low tens of minutes.
String formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  if (totalSeconds < 60) return '${totalSeconds}s';
  return '${totalSeconds ~/ 60}m ${totalSeconds % 60}s';
}

/// A vector equivalent for use in circular avatars — a
/// custom icon-on-tinted-background reads as more deliberately designed
/// than a platform emoji, and renders identically everywhere.
IconData platformIconData(String platform) {
  switch (platform) {
    case 'macos':
    case 'windows':
    case 'linux':
      return Icons.computer_rounded;
    case 'android':
    case 'ios':
      return Icons.smartphone_rounded;
    default:
      return Icons.devices_other_rounded;
  }
}
