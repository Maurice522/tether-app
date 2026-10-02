import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/transfer.dart';
import '../../state/app_state.dart';
import '../../theme/tether_theme.dart';
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
    final colors = context.colors;
    final request = widget.request;
    final alreadyTrusted = appState.isSenderTrusted(request.senderId);
    final totalBytes = request.totalBytes;

    return AlertDialog(
      title: Text('Incoming files from ${request.senderName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(request.senderAddress, style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12.5, color: colors.muted)),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: colors.surface2, borderRadius: BorderRadius.circular(12)),
              // A plain Column in a SingleChildScrollView, not a ListView —
              // AlertDialog's content is measured intrinsically by Material,
              // and ListView's Sliver-based viewport explicitly doesn't
              // support intrinsic-dimension queries (it throws), which was
              // silently taking down the whole dialog's layout with it.
              child: SingleChildScrollView(
                child: Column(
                  children: request.files
                      .map((f) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Icon(Icons.insert_drive_file_outlined, size: 17, color: colors.muted),
                                const SizedBox(width: 8),
                                Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5))),
                                Text(formatBytes(f.size), style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12, color: colors.faint)),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('Total: ${formatBytes(totalBytes)}', style: TextStyle(color: colors.muted, fontSize: 12.5)),
            const SizedBox(height: 16),
            if (!alreadyTrusted) ...[
              Text("Confirm this code matches the sender's screen:", style: TextStyle(color: colors.muted)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(color: colors.accentGlow, borderRadius: BorderRadius.circular(14)),
                child: Center(
                  child: Text(
                    request.pairingCode,
                    style:
                        TextStyle(fontFamily: 'Geist Mono', fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 6, color: colors.accentText),
                  ),
                ),
              ),
              const SizedBox(height: 8),
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
                children: [
                  Icon(Icons.verified_user_rounded, size: 17, color: colors.ok),
                  const SizedBox(width: 6),
                  const Text('Trusted device'),
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
