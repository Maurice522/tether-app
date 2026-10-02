import 'package:flutter/material.dart';

/// A refresh icon button that spins while [onRefresh] is in flight.
/// Without this, tapping refresh gives no feedback at all while the
/// actual network round-trip happens invisibly in the background, which
/// makes the button feel broken even when it's doing real work.
class RefreshButton extends StatefulWidget {
  final Future<void> Function() onRefresh;

  const RefreshButton({super.key, required this.onRefresh});

  @override
  State<RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<RefreshButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  bool _refreshing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    _controller.repeat();
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
        _controller
          ..stop()
          ..reset();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: RotationTransition(turns: _controller, child: const Icon(Icons.refresh_rounded)),
      tooltip: 'Refresh',
      onPressed: _refreshing ? null : _handleTap,
    );
  }
}
