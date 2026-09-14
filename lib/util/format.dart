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
