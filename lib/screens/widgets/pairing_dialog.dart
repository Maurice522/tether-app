import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/pairing_request.dart';
import '../../state/app_state.dart';

/// Shows progress for a pairing attempt this device initiated: the code
/// to compare, then the outcome once the other side responds.
class PairingDialog extends StatelessWidget {
  final String attemptId;

  const PairingDialog({super.key, required this.attemptId});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final attempt = appState.pairingAttempts[attemptId];

    if (attempt == null) {
      return const AlertDialog(content: SizedBox(height: 40, child: Center(child: CircularProgressIndicator())));
    }

    final isTerminal = attempt.status != PairingStatus.waiting;

    return AlertDialog(
      title: Text('Pairing with ${attempt.peerName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (attempt.status == PairingStatus.waiting) ...[
            const Text('Confirm this code matches on the other device:'),
            const SizedBox(height: 6),
            Center(
              child: Text(
                attempt.code,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                    ),
              ),
            ),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
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
    switch (status) {
      case PairingStatus.accepted:
        return const Row(children: [Icon(Icons.check_circle, color: Colors.green), SizedBox(width: 8), Text('Paired')]);
      case PairingStatus.declined:
        return const Row(children: [Icon(Icons.cancel, color: Colors.red), SizedBox(width: 8), Text('Declined')]);
      case PairingStatus.failed:
        return Row(children: [const Icon(Icons.error, color: Colors.red), const SizedBox(width: 8), Expanded(child: Text(error ?? 'Failed'))]);
      default:
        return const SizedBox.shrink();
    }
  }
}
