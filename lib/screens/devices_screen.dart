import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../state/app_state.dart';
import '../util/format.dart';
import 'widgets/add_device_dialog.dart';
import 'widgets/outgoing_transfer_dialog.dart';
import 'widgets/pairing_dialog.dart';

/// Desktop platforms support dragging files in from Finder/Explorer;
/// there's no equivalent "drop a file from outside the app" gesture on
/// Android, so the drop target there would only ever be inert.
bool get _supportsFileDrop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

Future<void> _sendFiles(BuildContext context, Device device, List<File> files) async {
  if (files.isEmpty || !context.mounted) return;
  final appState = context.read<AppState>();
  final transferId = appState.sendFiles(device, files);

  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (_) => OutgoingTransferDialog(transferId: transferId),
  );
}

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  Future<void> _pickAndSend(BuildContext context, Device device) async {
    final picked = await FilePicker.pickFiles();
    final files = picked.map((f) => f.path).whereType<String>().map(File.new).toList();
    if (!context.mounted) return;
    await _sendFiles(context, device, files);
  }

  void _pair(BuildContext context, Device device) {
    final appState = context.read<AppState>();
    final attemptId = appState.initiatePairing(device);
    showDialog(
      context: context,
      builder: (_) => PairingDialog(attemptId: attemptId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final devices = appState.devices;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add device by IP',
            onPressed: () => showDialog(context: context, builder: (_) => const AddDeviceDialog()),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => appState.refreshDevices(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (appState.startupError != null)
            MaterialBanner(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              content: Text(appState.startupError!),
              actions: [
                TextButton(
                  onPressed: () => appState.dismissStartupError(),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => appState.refreshDevices(),
              child: devices.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                itemCount: devices.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, index) {
                  final device = devices[index];
                  final trusted = appState.isSenderTrusted(device.id);
                  return _DeviceTile(
                    device: device,
                    trusted: trusted,
                    onSend: () => _pickAndSend(context, device),
                    onPair: () => _pair(context, device),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row in the Nearby Devices list. On desktop, doubles as a drop
/// target: dragging files from Finder/Explorer directly onto a device's
/// row sends them to that device, no file picker needed.
class _DeviceTile extends StatefulWidget {
  final Device device;
  final bool trusted;
  final VoidCallback onSend;
  final VoidCallback onPair;

  const _DeviceTile({
    required this.device,
    required this.trusted,
    required this.onSend,
    required this.onPair,
  });

  @override
  State<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<_DeviceTile> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final trusted = widget.trusted;

    final tile = Container(
      color: _dragging ? Theme.of(context).colorScheme.primaryContainer : null,
      child: ListTile(
        leading: Text(platformIcon(device.platform), style: const TextStyle(fontSize: 28)),
        title: Text(device.name),
        subtitle: Text(
          _dragging ? 'Drop to send' : '${device.address}${trusted ? ' · Paired' : ''}',
        ),
        trailing: trusted
            ? FilledButton.tonal(onPressed: widget.onSend, child: const Text('Send'))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(onPressed: widget.onPair, child: const Text('Pair')),
                  const SizedBox(width: 8),
                  FilledButton.tonal(onPressed: widget.onSend, child: const Text('Send')),
                ],
              ),
      ),
    );

    if (!_supportsFileDrop) return tile;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        final files = details.files.map((f) => File(f.path)).toList();
        _sendFiles(context, device, files);
      },
      child: tile,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_tethering, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              'Looking for devices on your network...\nMake sure other devices have LAN Share open and are on the same Wi-Fi.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            Text(
              "Can't find a device? Tap the + above to connect using its IP address instead — "
              "open Settings on that device to see its IP.",
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
