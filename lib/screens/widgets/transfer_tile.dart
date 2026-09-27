import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../../theme/tether_theme.dart';
import '../../util/format.dart';
import '../../util/reveal.dart';

class TransferTile extends StatelessWidget {
  final TransferRecord record;

  const TransferTile({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isIncoming = record.direction == TransferDirection.incoming;
    final isActive = record.status == TransferStatus.pendingApproval || record.status == TransferStatus.transferring;
    final canReveal = !isActive && isIncoming && record.status == TransferStatus.completed && record.savedPaths.isNotEmpty;
    final title = record.files.length == 1 ? record.files.first.name : '${record.files.length} files';
    final subtitle = isIncoming ? 'From ${record.peerName}' : 'To ${record.peerName}';
    final statusColor = _statusColor(colors, record.status);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: Icon(isIncoming ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, color: statusColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                if (record.status == TransferStatus.transferring) ...[
                  Text(subtitle, style: TextStyle(color: colors.muted, fontSize: 13)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: record.progress == 0 ? null : record.progress,
                      minHeight: 5,
                      backgroundColor: colors.line,
                      valueColor: AlwaysStoppedAnimation(colors.accentText),
                    ),
                  ),
                ] else
                  Text(
                    '$subtitle · ${_statusLabel(record.status)}',
                    style: TextStyle(color: colors.muted, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          isActive
              ? IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: 'Cancel',
                  onPressed: () => context.read<AppState>().cancelTransfer(record.id),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(formatBytes(record.totalBytes), style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12, color: colors.faint)),
                    if (canReveal)
                      IconButton(
                        icon: const Icon(Icons.folder_open_rounded, size: 19),
                        tooltip: 'Show in folder',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        onPressed: () => record.savedPaths.length == 1
                            ? revealFile(record.savedPaths.first)
                            : openFolder(File(record.savedPaths.first).parent.path),
                      ),
                  ],
                ),
        ],
      ),
    );
  }

  Color _statusColor(TetherColors colors, TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return colors.ok;
      case TransferStatus.failed:
      case TransferStatus.declined:
        return colors.danger;
      case TransferStatus.canceled:
        return colors.faint;
      default:
        return colors.accentText;
    }
  }

  String _statusLabel(TransferStatus status) {
    switch (status) {
      case TransferStatus.pendingApproval:
        return 'Waiting';
      case TransferStatus.transferring:
        return 'Transferring';
      case TransferStatus.completed:
        return 'Completed';
      case TransferStatus.declined:
        return 'Declined';
      case TransferStatus.failed:
        return 'Failed';
      case TransferStatus.canceled:
        return 'Canceled';
    }
  }
}
