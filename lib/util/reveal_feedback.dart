import 'package:flutter/material.dart';

/// Runs a reveal/open action (see reveal.dart) and tells the user when it
/// silently couldn't do anything (mainly an Android reality — there's no
/// app on every device willing to browse an arbitrary folder) instead of
/// just doing nothing.
Future<void> revealWithFeedback(BuildContext context, Future<bool> Function() action) async {
  final ok = await action();
  if (ok || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text("Couldn't open — no app on this device can handle it")),
  );
}
