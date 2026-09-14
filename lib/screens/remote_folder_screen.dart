import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../models/remote_entry.dart';
import '../state/app_state.dart';
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
    final title = _path.isEmpty ? widget.device.name : _path.split('/').last;
    return PopScope(
      canPop: _path.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: _path.isEmpty
              ? null
              : IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goUp),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: () => setState(() => _future = _load()),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () async => setState(() => _future = _load()),
          child: FutureBuilder<List<RemoteEntry>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
                      child: Text(
                        'Could not load this folder.\n${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  ],
                );
              }
              final entries = snapshot.data ?? const [];
              if (entries.isEmpty) {
                return ListView(
                  children: const [
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 64),
                      child: Text('Empty folder', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                    ),
                  ],
                );
              }
              return ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, index) {
                  final entry = entries[index];
                  return ListTile(
                    leading: Icon(entry.isDir ? Icons.folder : Icons.insert_drive_file_outlined),
                    title: Text(entry.name),
                    subtitle: entry.isDir ? null : Text(formatBytes(entry.size)),
                    trailing: entry.isDir
                        ? const Icon(Icons.chevron_right)
                        : IconButton(
                            icon: const Icon(Icons.download_outlined),
                            tooltip: 'Download',
                            onPressed: () => _download(entry),
                          ),
                    onTap: entry.isDir ? () => _openDir(entry.name) : () => _download(entry),
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
