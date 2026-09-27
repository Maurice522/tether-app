import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../state/app_state.dart';
import '../theme/tether_theme.dart';
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
    final colors = context.colors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Add device by IP',
            onPressed: () => showDialog(context: context, builder: (_) => const AddDeviceDialog()),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () => appState.refreshDevices(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (appState.startupError != null)
            MaterialBanner(
              backgroundColor: colors.danger.withValues(alpha: 0.12),
              leading: Icon(Icons.error_outline_rounded, color: colors.danger),
              content: Text(appState.startupError!, style: TextStyle(color: colors.text)),
              actions: [
                TextButton(
                  onPressed: () => appState.dismissStartupError(),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          Expanded(
            child: RefreshIndicator(
              color: colors.accentText,
              backgroundColor: colors.surface,
              onRefresh: () async => appState.refreshDevices(),
              child: devices.isEmpty
                  ? const _EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: devices.length,
                      itemBuilder: (ctx, index) {
                        final device = devices[index];
                        final trusted = appState.isSenderTrusted(device.id);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _EntranceFade(
                            index: index,
                            child: _DeviceTile(
                              device: device,
                              trusted: trusted,
                              onSend: () => _pickAndSend(context, device),
                              onPair: () => _pair(context, device),
                            ),
                          ),
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

/// A gentle staggered fade-and-rise for list items on first appearance —
/// the kind of small motion that makes a list feel considered rather than
/// items just snapping into place.
class _EntranceFade extends StatefulWidget {
  final int index;
  final Widget child;

  const _EntranceFade({required this.index, required this.child});

  @override
  State<_EntranceFade> createState() => _EntranceFadeState();
}

class _EntranceFadeState extends State<_EntranceFade> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
    final curved = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _fade = curved;
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(curved);
    Future.delayed(Duration(milliseconds: 30 * widget.index.clamp(0, 6)), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
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
    final colors = context.colors;

    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: _dragging ? colors.accentGlow : colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _dragging ? colors.accentText : colors.line, width: _dragging ? 1.6 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: trusted ? colors.accentGlow : colors.surface2,
            child: Icon(platformIconData(device.platform), color: trusted ? colors.accentText : colors.muted, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name, style: Theme.of(context).textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  _dragging ? 'Drop to send' : device.address,
                  style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12.5, color: _dragging ? colors.accentText : colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (trusted) ...[
            Icon(Icons.link_rounded, size: 15, color: colors.accentText),
            const SizedBox(width: 6),
          ],
          trusted
              ? FilledButton(onPressed: widget.onSend, child: const Text('Send'))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton(onPressed: widget.onPair, child: const Text('Pair')),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: widget.onSend, child: const Text('Send')),
                  ],
                ),
        ],
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
                  child: Icon(Icons.wifi_tethering_rounded, size: 34, color: colors.faint),
                ),
                const SizedBox(height: 24),
                Text(
                  'Looking for devices…',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Make sure other devices have Tether open and are on the same Wi-Fi.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted, height: 1.4),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colors.surface2,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: colors.line),
                  ),
                  child: Text(
                    "Can't find a device? Tap + above to connect using its IP address — "
                    'open Settings on that device to see its IP.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.muted, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
