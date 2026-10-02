import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../models/pairing_request.dart';
import '../state/app_state.dart';
import '../theme/tether_theme.dart';
import '../util/format.dart';
import '../util/send_flow.dart';
import 'qr_scan_screen.dart';
import 'widgets/add_device_dialog.dart';
import 'widgets/pairing_dialog.dart';
import 'widgets/refresh_button.dart';

/// Desktop platforms support dragging files in from Finder/Explorer;
/// there's no equivalent "drop a file from outside the app" gesture on
/// Android, so the drop target there would only ever be inert.
bool get _supportsFileDrop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  // One stable GlobalKey per device, reused across rebuilds — lets the
  // window-level drop fallback below hit-test a drop's position against
  // each tile's actual on-screen bounds. desktop_drop's DropTarget doesn't
  // do tree-based hit-testing (every registered instance independently
  // checks its own bounds against the raw OS event), so nesting one
  // DropTarget inside another would fire BOTH for the same drop — this
  // hit-test is what makes the window-level one act only as a fallback for
  // drops that didn't land on any tile, instead of double-sending.
  final Map<String, GlobalKey> _tileKeys = {};

  GlobalKey _keyFor(String deviceId) => _tileKeys.putIfAbsent(deviceId, GlobalKey.new);

  String? _deviceIdAt(Offset globalPosition) {
    for (final entry in _tileKeys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox) continue;
      final local = renderObject.globalToLocal(globalPosition);
      if (renderObject.paintBounds.contains(local)) return entry.key;
    }
    return null;
  }

  Future<void> _pickAndSend(BuildContext context, Device device) async {
    final picked = await FilePicker.pickFiles();
    final files = picked.map((f) => f.path).whereType<String>().map(File.new).toList();
    if (!context.mounted) return;
    await sendFilesToDevice(context, device, files);
  }

  void _pair(BuildContext context, Device device) {
    final appState = context.read<AppState>();
    // Guards against a rapid double-tap firing this twice before the
    // first dialog's pop animation removes the button — without it, two
    // concurrent pairing attempts start and two dialogs stack up.
    final alreadyPairing = appState.pairingAttempts.values
        .any((a) => a.peerId == device.id && a.status == PairingStatus.waiting);
    if (alreadyPairing) return;
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
    _tileKeys.removeWhere((id, _) => !devices.any((d) => d.id == id));

    final scaffold = Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        actions: [
          if (Platform.isAndroid)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner_rounded),
              tooltip: 'Scan QR code',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrScanScreen())),
            ),
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Add device by IP',
            onPressed: () => showDialog(context: context, builder: (_) => const AddDeviceDialog()),
          ),
          RefreshButton(onRefresh: appState.refreshDevices),
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
              onRefresh: () => appState.refreshDevices(),
              child: devices.isEmpty
                  ? const _EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: devices.length,
                      itemBuilder: (ctx, index) {
                        final device = devices[index];
                        final trusted = appState.isSenderTrusted(device.id);
                        return Padding(
                          key: _keyFor(device.id),
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

    if (!_supportsFileDrop) return scaffold;

    // Window-level fallback: a drop that lands on a specific tile is
    // handled entirely by that tile's own DropTarget (below); this one
    // only acts when the drop didn't land on any tile — window minimized
    // to nothing but a title bar, or dropped on empty space — since
    // there's otherwise no way to say which device it was meant for.
    return DropTarget(
      onDragDone: (details) {
        if (_deviceIdAt(details.globalPosition) != null) return;
        final files = details.files.map((f) => File(f.path)).toList();
        pickTargetDeviceAndSend(context, files);
      },
      child: scaffold,
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

    final compactButtonPadding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10);

    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: _dragging ? colors.accentGlow : colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _dragging ? colors.accentText : colors.line, width: _dragging ? 1.6 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: trusted ? colors.accentGlow : colors.surface2,
                child: Icon(platformIconData(device.platform), color: trusted ? colors.accentText : colors.muted, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(device.name, style: Theme.of(context).textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        if (trusted) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.link_rounded, size: 14, color: colors.accentText),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _dragging ? 'Drop to send' : device.address,
                      style: TextStyle(fontFamily: 'Geist Mono', fontSize: 12.5, color: _dragging ? colors.accentText : colors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!trusted) ...[
                OutlinedButton(
                  style: OutlinedButton.styleFrom(padding: compactButtonPadding),
                  onPressed: widget.onPair,
                  child: const Text('Pair'),
                ),
                const SizedBox(width: 8),
              ],
              FilledButton(
                style: FilledButton.styleFrom(padding: compactButtonPadding),
                onPressed: widget.onSend,
                child: const Text('Send'),
              ),
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
        sendFilesToDevice(context, device, files);
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
