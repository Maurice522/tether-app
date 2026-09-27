import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../models/remote_entry.dart';
import '../state/app_state.dart';
import '../theme/tether_theme.dart';
import '../util/format.dart';

/// Browses one paired device's shared folder, starting at its root.
/// Tapping a folder navigates into it; tapping a file (or its download
/// icon) pulls it straight into this device's own shared folder, no
/// prompt — pairing already established the trust.
class RemoteFolderScreen extends StatefulWidget {
  final Device device;

  const RemoteFolderScreen({super.key, required this.device});

  @override
  State<RemoteFolderScreen> createState() => _RemoteFolderScreenState();
}

class _RemoteFolderScreenState extends State<RemoteFolderScreen> {
  String _path = '';
  late Future<List<RemoteEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<RemoteEntry>> _load() {
    return context.read<AppState>().browseDevice(widget.device, _path);
  }

  void _openDir(String name) {
    setState(() {
      _path = _path.isEmpty ? name : '$_path/$name';
      _future = _load();
    });
  }

  void _goUp() {
    final idx = _path.lastIndexOf('/');
    setState(() {
      _path = idx == -1 ? '' : _path.substring(0, idx);
      _future = _load();
    });
  }

  void _download(RemoteEntry entry) {
    context.read<AppState>().startDownload(widget.device, entry, _path);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Downloading ${entry.name}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = _path.isEmpty ? widget.device.name : _path.split('/').last;
    return PopScope(
      canPop: _path.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: _path.isEmpty ? null : IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: _goUp),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh',
              onPressed: () => setState(() => _future = _load()),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: RefreshIndicator(
          color: colors.accentText,
          backgroundColor: colors.surface,
          onRefresh: () async => setState(() => _future = _load()),
          child: FutureBuilder<List<RemoteEntry>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Center(child: CircularProgressIndicator(color: colors.accentText));
              }
              if (snapshot.hasError) {
                return ListView(
                  padding: const EdgeInsets.symmetric(vertical: 64),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'Could not load this folder.\n${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.muted),
                      ),
                    ),
                  ],
                );
              }
              final entries = snapshot.data ?? const [];
              if (entries.isEmpty) {
                return ListView(
                  padding: const EdgeInsets.symmetric(vertical: 64),
                  children: [
                    Center(child: Text('Empty folder', style: TextStyle(color: colors.muted))),
                  ],
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: entries.length,
                itemBuilder: (ctx, index) {
                  final entry = entries[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: colors.line),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: entry.isDir ? () => _openDir(entry.name) : () => _download(entry),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: entry.isDir ? colors.accentGlow : colors.surface2,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  entry.isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
                                  size: 19,
                                  color: entry.isDir ? colors.accentText : colors.muted,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
                                    if (!entry.isDir) ...[
                                      const SizedBox(height: 2),
                                      Text(formatBytes(entry.size), style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12, color: colors.muted)),
                                    ],
                                  ],
                                ),
                              ),
                              entry.isDir
                                  ? Icon(Icons.chevron_right_rounded, color: colors.faint)
                                  : IconButton(
                                      icon: const Icon(Icons.download_rounded, size: 20),
                                      tooltip: 'Download',
                                      onPressed: () => _download(entry),
                                    ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
