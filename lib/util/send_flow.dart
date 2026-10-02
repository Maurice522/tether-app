import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../screens/widgets/outgoing_transfer_dialog.dart';
import '../state/app_state.dart';
import '../theme/tether_theme.dart';
import 'format.dart';

/// Sends [files] to [device] and shows the usual outgoing-transfer dialog —
/// the one path every "send" flow in the app funnels into, whether the
/// device was already known (tapping its tile) or was just picked from
/// [pickTargetDeviceAndSend] (a share-sheet hand-off, or a drop that didn't
/// land on a specific tile).
Future<void> sendFilesToDevice(BuildContext context, Device device, List<File> files) async {
  if (files.isEmpty || !context.mounted) return;
  final appState = context.read<AppState>();
  final transferId = appState.sendFiles(device, files);

  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (_) => OutgoingTransferDialog(transferId: transferId),
  );
}

/// Asks the user which known device to send [files] to, then sends them —
/// for the cases where files arrive without a specific device already
/// chosen (a share-sheet hand-off, or a drop that landed on empty space
/// rather than a device tile).
Future<void> pickTargetDeviceAndSend(BuildContext context, List<File> files) async {
  if (files.isEmpty || !context.mounted) return;
  final appState = context.read<AppState>();
  final devices = appState.devices;
  if (devices.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No devices found to send to')),
    );
    return;
  }

  final device = await showModalBottomSheet<Device>(
    context: context,
    builder: (_) => _DevicePickerSheet(devices: devices),
  );
  if (device == null || !context.mounted) return;
  await sendFilesToDevice(context, device, files);
}

class _DevicePickerSheet extends StatelessWidget {
  final List<Device> devices;

  const _DevicePickerSheet({required this.devices});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Send to…', style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          for (final device in devices)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.surface2,
                child: Icon(platformIconData(device.platform), color: colors.muted),
              ),
              title: Text(device.name),
              subtitle: Text(device.address, style: const TextStyle(fontFamily: 'Geist Mono', fontSize: 12)),
              onTap: () => Navigator.of(context).pop(device),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
