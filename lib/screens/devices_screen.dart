import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../state/app_state.dart';
import '../util/format.dart';
import 'widgets/outgoing_transfer_dialog.dart';
import 'widgets/pairing_dialog.dart';

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  Future<void> _pickAndSend(BuildContext context, Device device) async {
    final picked = await FilePicker.pickFiles();
    final files = picked.map((f) => f.path).whereType<String>().map(File.new).toList();
    if (files.isEmpty || !context.mounted) return;

    final appState = context.read<AppState>();
    final transferId = appState.sendFiles(device, files);

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => OutgoingTransferDialog(transferId: transferId),
    );
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
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => appState.refreshDevices(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => appState.refreshDevices(),
        child: devices.isEmpty
            ? const _EmptyState()
            : ListView.separated(
                itemCount: devices.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, index) {
                  final device = devices[index];
                  final trusted = appState.isSenderTrusted(device.id);
                  return ListTile(
                    leading: Text(platformIcon(device.platform), style: const TextStyle(fontSize: 28)),
                    title: Text(device.name),
                    subtitle: Text('${device.address}${trusted ? ' · Paired' : ''}'),
                    trailing: trusted
                        ? FilledButton.tonal(
                            onPressed: () => _pickAndSend(context, device),
                            child: const Text('Send'),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OutlinedButton(
                                onPressed: () => _pair(context, device),
                                child: const Text('Pair'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonal(
                                onPressed: () => _pickAndSend(context, device),
                                child: const Text('Send'),
                              ),
                            ],
                          ),
                  );
                },
              ),
      ),
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
          ],
        ),
      ),
    );
  }
}
