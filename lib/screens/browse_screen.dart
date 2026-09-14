import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../util/format.dart';
import 'remote_folder_screen.dart';

/// Lists paired devices that are currently online, as the entry point for
/// browsing another device's shared folder.
class BrowseScreen extends StatelessWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final pairedOnline = appState.devices.where((d) => appState.isSenderTrusted(d.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse'),
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
        child: pairedOnline.isEmpty
            ? const _EmptyBrowseState()
            : ListView.separated(
                itemCount: pairedOnline.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, index) {
                  final device = pairedOnline[index];
                  return ListTile(
                    leading: Text(platformIcon(device.platform), style: const TextStyle(fontSize: 28)),
                    title: Text(device.name),
                    subtitle: Text(device.address),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => RemoteFolderScreen(device: device)),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _EmptyBrowseState extends StatelessWidget {
  const _EmptyBrowseState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_shared_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                'No paired devices online.\nPair with a device from Nearby Devices, then come back here '
                'to browse its shared folder.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
