import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/tether_theme.dart';
import '../util/format.dart';
import 'remote_folder_screen.dart';
import 'widgets/refresh_button.dart';

/// Lists paired devices that are currently online, as the entry point for
/// browsing another device's shared folder.
class BrowseScreen extends StatelessWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final colors = context.colors;
    final pairedOnline = appState.devices.where((d) => appState.isSenderTrusted(d.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse'),
        actions: [
          RefreshButton(onRefresh: appState.refreshDevices),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        color: colors.accentText,
        backgroundColor: colors.surface,
        onRefresh: () => appState.refreshDevices(),
        child: pairedOnline.isEmpty
            ? const _EmptyBrowseState()
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: pairedOnline.length,
                itemBuilder: (ctx, index) {
                  final device = pairedOnline[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colors.line),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => RemoteFolderScreen(device: device)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: colors.accentGlow,
                                child: Icon(platformIconData(device.platform), color: colors.accentText, size: 22),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(device.name, style: Theme.of(context).textTheme.titleSmall),
                                    const SizedBox(height: 2),
                                    Text(
                                      device.address,
                                      style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12.5, color: colors.muted),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded, color: colors.faint),
                            ],
                          ),
                        ),
                      ),
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
    final colors = context.colors;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 80),
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(color: colors.surface2, shape: BoxShape.circle),
                  child: Icon(Icons.folder_shared_rounded, size: 34, color: colors.faint),
                ),
                const SizedBox(height: 24),
                Text('No paired devices online', style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'Pair with a device from Nearby Devices, then come back here to browse its shared folder.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
