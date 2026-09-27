import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/pairing_request.dart';
import '../../state/app_state.dart';
import '../../theme/tether_theme.dart';

/// Shows progress for a pairing attempt this device initiated: the code
/// to compare, then the outcome once the other side responds.
class PairingDialog extends StatelessWidget {
  final String attemptId;

  const PairingDialog({super.key, required this.attemptId});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final colors = context.colors;
    final attempt = appState.pairingAttempts[attemptId];

    if (attempt == null) {
      return AlertDialog(content: SizedBox(height: 40, child: Center(child: CircularProgressIndicator(color: colors.accentText))));
    }

    final isTerminal = attempt.status != PairingStatus.waiting;

    return AlertDialog(
      title: Text('Pairing with ${attempt.peerName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (attempt.status == PairingStatus.waiting) ...[
            Text('Confirm this code matches on the other device:', style: TextStyle(color: colors.muted)),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(color: colors.accentGlow, borderRadius: BorderRadius.circular(14)),
              child: Center(
                child: Text(
                  attempt.code,
                  style: TextStyle(fontFamily: 'Geist Mono', fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 6, color: colors.accentText),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(minHeight: 4, backgroundColor: colors.line, valueColor: AlwaysStoppedAnimation(colors.accentText)),
            ),
          ] else
            _StatusLine(status: attempt.status, error: attempt.error),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(isTerminal ? 'Done' : 'Hide'),
        ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  final PairingStatus status;
  final String? error;

  const _StatusLine({required this.status, this.error});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    switch (status) {
      case PairingStatus.accepted:
        return Row(children: [Icon(Icons.check_circle_rounded, color: colors.ok), const SizedBox(width: 8), const Text('Paired')]);
      case PairingStatus.declined:
        return Row(children: [Icon(Icons.cancel_rounded, color: colors.danger), const SizedBox(width: 8), const Text('Declined')]);
      case PairingStatus.failed:
        return Row(children: [
          Icon(Icons.error_rounded, color: colors.danger),
          const SizedBox(width: 8),
          Expanded(child: Text(error ?? 'Failed')),
        ]);
      default:
        return const SizedBox.shrink();
    }
  }
}
