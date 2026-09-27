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
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unitIndex]}';
}

String platformIcon(String platform) {
  switch (platform) {
    case 'macos':
      return '🖥️';
    case 'windows':
      return '💻';
    case 'android':
      return '📱';
    case 'ios':
      return '📱';
    case 'linux':
      return '🐧';
    default:
      return '📡';
  }
}

/// A vector equivalent of [platformIcon] for use in circular avatars — a
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
