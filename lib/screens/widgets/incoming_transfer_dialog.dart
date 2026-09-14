import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../../util/format.dart';

/// Accept/decline prompt for an incoming offer. If the sender isn't
/// already trusted, shows the pairing code so the user can compare it
/// against what the sender's device is displaying before accepting.
class IncomingTransferDialog extends StatefulWidget {
  final IncomingTransferRequest request;

  const IncomingTransferDialog({super.key, required this.request});

  @override
  State<IncomingTransferDialog> createState() => _IncomingTransferDialogState();
}

class _IncomingTransferDialogState extends State<IncomingTransferDialog> {
  bool _trustDevice = false;

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    final request = widget.request;
    final alreadyTrusted = appState.isSenderTrusted(request.senderId);
    final totalBytes = request.files.fold<int>(0, (s, f) => s + f.size);

    return AlertDialog(
      title: Text('Incoming files from ${request.senderName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(request.senderAddress, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView(
                shrinkWrap: true,
                children: request.files
                    .map((f) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(Icons.insert_drive_file_outlined, size: 18),
                              const SizedBox(width: 8),
                              Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis)),
                              Text(formatBytes(f.size), style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
            Text('Total: ${formatBytes(totalBytes)}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            if (!alreadyTrusted) ...[
              const Text('Confirm this code matches the sender\'s screen:'),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  request.pairingCode,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                      ),
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _trustDevice,
                onChanged: (v) => setState(() => _trustDevice = v ?? false),
                title: const Text('Trust this device'),
                subtitle: const Text('Skip the code check next time'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ] else
              Row(
                children: const [
                  Icon(Icons.verified_user_outlined, size: 18, color: Colors.green),
                  SizedBox(width: 6),
                  Text('Trusted device'),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            appState.respondToIncoming(request, false);
          },
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            appState.respondToIncoming(request, true, trustAfter: _trustDevice);
          },
          child: const Text('Accept'),
        ),
      ],
    );
  }
}
