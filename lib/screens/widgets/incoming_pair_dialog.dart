import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/pairing_request.dart';
import '../../state/app_state.dart';
import '../../theme/tether_theme.dart';

/// Accept/decline prompt for an incoming pair request. Accepting always
/// trusts the requester — pairing's whole purpose is establishing trust,
/// so there's no separate checkbox like the (untrusted) transfer dialog.
class IncomingPairDialog extends StatelessWidget {
  final IncomingPairRequest request;

  const IncomingPairDialog({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    final colors = context.colors;

    return AlertDialog(
      title: Text('Pair with ${request.requesterName}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(request.requesterAddress, style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12.5, color: colors.muted)),
          const SizedBox(height: 16),
          Text("Confirm this code matches the other device's screen:", style: TextStyle(color: colors.muted)),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(color: colors.accentGlow, borderRadius: BorderRadius.circular(14)),
            child: Center(
              child: Text(
                request.code,
                style: TextStyle(fontFamily: 'Geist Mono', fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 6, color: colors.accentText),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Once paired, this device can send you files with no further prompts.',
            style: TextStyle(fontSize: 12.5, color: colors.faint),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            appState.respondToPairRequest(request, false);
          },
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            appState.respondToPairRequest(request, true);
          },
          child: const Text('Pair'),
        ),
      ],
    );
  }
}
