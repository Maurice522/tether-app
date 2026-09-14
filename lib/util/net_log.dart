/// Tagged console logging for diagnosing discovery/transfer issues live.
/// Temporary/verbose by design — safe to leave in since it's cheap, but
/// meant to be read from `flutter run`'s console during a debug session.
void netLog(String tag, String message) {
  // ignore: avoid_print
  print('[$tag] $message');
}
