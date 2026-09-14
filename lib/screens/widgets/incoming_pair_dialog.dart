import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/pairing_request.dart';
import '../../state/app_state.dart';

/// Accept/decline prompt for an incoming pair request. Accepting always
/// trusts the requester — pairing's whole purpose is establishing trust,
/// so there's no separate checkbox like the (untrusted) transfer dialog.
class IncomingPairDialog extends StatelessWidget {
  final IncomingPairRequest request;

  const IncomingPairDialog({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();

    return AlertDialog(
      title: Text('Pair with ${request.requesterName}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(request.requesterAddress, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          const Text('Confirm this code matches the other device\'s screen:'),
          const SizedBox(height: 6),
          Center(
            child: Text(
              request.code,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                  ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Once paired, this device can send you files with no further prompts.',
            style: Theme.of(context).textTheme.bodySmall,
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
