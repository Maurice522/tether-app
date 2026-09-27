import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/tether_theme.dart';
import '../../util/format.dart';

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

  Future<void> _connect([String? addressOverride]) async {
    final address = addressOverride ?? _controller.text.trim();
    if (address.isEmpty) return;
    _controller.text = address;
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
    final colors = context.colors;
    final recent = appState.manualDevices.all;
    return AlertDialog(
      title: const Text('Add device by IP'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Use this if a paired or nearby device isn't showing up automatically — "
            'enter its IP address (visible in its own Wi-Fi settings).',
            style: TextStyle(color: colors.muted, fontSize: 13, height: 1.4),
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
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 15, color: colors.danger),
                const SizedBox(width: 6),
                Expanded(child: Text(appState.manualAddError!, style: TextStyle(color: colors.danger, fontSize: 13))),
              ],
            ),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('RECENT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: colors.faint)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: recent
                  .map(
                    (d) => ActionChip(
                      avatar: CircleAvatar(
                        radius: 10,
                        backgroundColor: colors.accentGlow,
                        child: Icon(platformIconData(d.platform), size: 12, color: colors.accentText),
                      ),
                      label: Text('${d.name} (${d.address})'),
                      backgroundColor: colors.surface2,
                      side: BorderSide(color: colors.line),
                      onPressed: _connecting ? null : () => _connect(d.address),
                    ),
                  )
                  .toList(),
            ),
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
              ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: colors.accentInk))
              : const Text('Connect'),
        ),
      ],
    );
  }
}
