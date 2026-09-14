import 'package:flutter/material.dart';

import '../../models/transfer.dart';
import '../../util/format.dart';

class TransferTile extends StatelessWidget {
  final TransferRecord record;

  const TransferTile({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    final isIncoming = record.direction == TransferDirection.incoming;
    final title = record.files.length == 1
        ? record.files.first.name
        : '${record.files.length} files';
    final subtitle = isIncoming ? 'From ${record.peerName}' : 'To ${record.peerName}';

    return ListTile(
      leading: Icon(
        isIncoming ? Icons.download_rounded : Icons.upload_rounded,
        color: _statusColor(context, record.status),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: record.status == TransferStatus.transferring
          ? Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(subtitle),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: record.progress == 0 ? null : record.progress),
                  ),
                ],
              ),
            )
          : Text('$subtitle · ${_statusLabel(record.status)}'),
      trailing: Text(formatBytes(record.totalBytes), style: Theme.of(context).textTheme.bodySmall),
    );
  }

  Color? _statusColor(BuildContext context, TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return Colors.green;
      case TransferStatus.failed:
      case TransferStatus.declined:
        return Colors.red;
      case TransferStatus.canceled:
        return Colors.grey;
      default:
        return Theme.of(context).colorScheme.primary;
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
