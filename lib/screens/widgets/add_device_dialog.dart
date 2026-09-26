import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

/// Fallback for when broadcast discovery isn't finding a peer — probes an
/// IP address directly and adds it as a device on success.
class AddDeviceDialog extends StatefulWidget {
  const AddDeviceDialog({super.key});

  @override
  State<AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<AddDeviceDialog> {
  final _controller = TextEditingController();
  bool _connecting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final address = _controller.text.trim();
    if (address.isEmpty) return;
    setState(() => _connecting = true);

    final appState = context.read<AppState>();
    await appState.addManualDevice(address);

    if (!mounted) return;
    setState(() => _connecting = false);
    if (appState.manualAddError == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return AlertDialog(
      title: const Text('Add device by IP'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Use this if a paired or nearby device isn't showing up automatically — "
            'enter its IP address (visible in its own Wi-Fi settings).',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.1.42'),
            onSubmitted: (_) => _connecting ? null : _connect(),
          ),
          if (appState.manualAddError != null) ...[
            const SizedBox(height: 8),
            Text(appState.manualAddError!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _connecting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _connecting ? null : _connect,
          child: _connecting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect'),
        ),
      ],
    );
  }
}
