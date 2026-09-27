import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../../theme/tether_theme.dart';
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
    final colors = context.colors;
    final record = appState.activeTransfers[transferId] ??
        appState.completedTransfers.cast<TransferRecord?>().firstWhere(
              (r) => r?.id == transferId,
              orElse: () => null,
            );

    if (record == null) {
      return AlertDialog(content: SizedBox(height: 40, child: Center(child: CircularProgressIndicator(color: colors.accentText))));
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
            Text('Waiting for the other device to accept…', style: TextStyle(color: colors.muted)),
            if (record.pairingCode != null) ...[
              const SizedBox(height: 14),
              Text('If asked, confirm this code matches:', style: TextStyle(color: colors.muted)),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(color: colors.accentGlow, borderRadius: BorderRadius.circular(14)),
                child: Center(
                  child: Text(
                    record.pairingCode!,
                    style:
                        TextStyle(fontFamily: 'Geist Mono', fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 6, color: colors.accentText),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(minHeight: 4, backgroundColor: colors.line, valueColor: AlwaysStoppedAnimation(colors.accentText)),
            ),
          ] else if (record.status == TransferStatus.transferring) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: record.progress == 0 ? null : record.progress,
                minHeight: 6,
                backgroundColor: colors.line,
                valueColor: AlwaysStoppedAnimation(colors.accentText),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${formatBytes(record.bytesTransferred)} / ${formatBytes(record.totalBytes)}',
              style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12.5, color: colors.muted),
            ),
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
    final colors = context.colors;
    switch (status) {
      case TransferStatus.completed:
        return Row(children: [Icon(Icons.check_circle_rounded, color: colors.ok), const SizedBox(width: 8), const Text('Completed')]);
      case TransferStatus.declined:
        return Row(children: [Icon(Icons.cancel_rounded, color: colors.danger), const SizedBox(width: 8), const Text('Declined by recipient')]);
      case TransferStatus.failed:
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
