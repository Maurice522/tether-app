import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../../util/format.dart';

/// Shows progress for a transfer this device initiated. While the peer
/// hasn't accepted yet and isn't already trusted, displays the pairing
/// code so the user can read it aloud / compare it against the
/// receiver's screen. Safe to dismiss — the transfer keeps running.
class OutgoingTransferDialog extends StatelessWidget {
  final String transferId;

  const OutgoingTransferDialog({super.key, required this.transferId});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final record = appState.activeTransfers[transferId] ??
        appState.completedTransfers.cast<TransferRecord?>().firstWhere(
              (r) => r?.id == transferId,
              orElse: () => null,
            );

    if (record == null) {
      return const AlertDialog(content: SizedBox(height: 40, child: Center(child: CircularProgressIndicator())));
    }

    final isTerminal = record.status != TransferStatus.pendingApproval && record.status != TransferStatus.transferring;

    return AlertDialog(
      title: Text('Sending to ${record.peerName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(record.files.length == 1 ? record.files.first.name : '${record.files.length} files'),
          const SizedBox(height: 16),
          if (record.status == TransferStatus.pendingApproval) ...[
            const Text('Waiting for the other device to accept...'),
            if (record.pairingCode != null) ...[
              const SizedBox(height: 12),
              const Text('If asked, confirm this code matches:'),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  record.pairingCode!,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                      ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ] else if (record.status == TransferStatus.transferring) ...[
            LinearProgressIndicator(value: record.progress == 0 ? null : record.progress),
            const SizedBox(height: 8),
            Text('${formatBytes(record.bytesTransferred)} / ${formatBytes(record.totalBytes)}'),
          ] else
            _StatusLine(status: record.status, error: record.error),
        ],
      ),
      actions: [
        if (isTerminal)
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))
        else
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Hide')),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  final TransferStatus status;
  final String? error;

  const _StatusLine({required this.status, this.error});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case TransferStatus.completed:
        return const Row(children: [Icon(Icons.check_circle, color: Colors.green), SizedBox(width: 8), Text('Completed')]);
      case TransferStatus.declined:
        return const Row(children: [Icon(Icons.cancel, color: Colors.red), SizedBox(width: 8), Text('Declined by recipient')]);
      case TransferStatus.failed:
        return Row(children: [const Icon(Icons.error, color: Colors.red), const SizedBox(width: 8), Expanded(child: Text(error ?? 'Failed'))]);
      default:
        return const SizedBox.shrink();
    }
  }
}
