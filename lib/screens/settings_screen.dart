import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../util/network_info.dart';
import '../util/reveal.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameController;
  List<String> _ipAddresses = [];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: context.read<AppState>().settings.deviceName);
    localIpAddresses().then((addresses) {
      if (mounted) setState(() => _ipAddresses = addresses);
    });
  }

  void _copyIp(String address) {
    Clipboard.setData(ClipboardData(text: address));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $address'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _saveName() {
    final value = _nameController.text.trim();
    if (value.isEmpty) return;
    context.read<AppState>().updateDeviceName(value);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device name saved'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _confirmQuit(BuildContext context) async {
    final appState = context.read<AppState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quit LAN Share?'),
        content: const Text(
          "This fully stops the app, including discovery and the background service — other "
          "devices won't be able to reach you until you reopen it. Closing the app normally "
          '(without quitting) keeps all of that running.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Quit')),
        ],
      ),
    );
    if (confirmed == true) {
      await appState.quitApp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final trustedIds = appState.pairing.trustedIds;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Device name', border: OutlineInputBorder()),
                    onSubmitted: (_) => _saveName(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _saveName, child: const Text('Save')),
              ],
            ),
          ),
          if (_ipAddresses.isEmpty)
            const ListTile(
              title: Text('This device\'s IP address'),
              subtitle: Text('Looking it up…'),
            )
          else
            for (var i = 0; i < _ipAddresses.length; i++)
              ListTile(
                title: Text(_ipAddresses.length > 1 ? 'IP address ${i + 1}' : 'This device\'s IP address'),
                subtitle: Text(_ipAddresses[i]),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy',
                  onPressed: () => _copyIp(_ipAddresses[i]),
                ),
              ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Type this into "Add device by IP" on another device if it isn\'t showing up automatically.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          ListTile(
            title: const Text('Download folder'),
            subtitle: Text(appState.settings.downloadDir),
            trailing: IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Reveal in Finder',
              onPressed: () => openFolder(appState.settings.downloadDir),
            ),
            onTap: () async {
              final path = await FilePicker.getDirectoryPath();
              if (path != null) await appState.updateDownloadDir(path);
            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Theme', style: Theme.of(context).textTheme.labelLarge),
          ),
          RadioGroup<ThemeMode>(
            groupValue: appState.themeMode,
            onChanged: (v) => appState.updateThemeMode(v!),
            child: const Column(
              children: [
                RadioListTile<ThemeMode>(title: Text('System'), value: ThemeMode.system),
                RadioListTile<ThemeMode>(title: Text('Light'), value: ThemeMode.light),
                RadioListTile<ThemeMode>(title: Text('Dark'), value: ThemeMode.dark),
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Clipboard sync', style: Theme.of(context).textTheme.labelLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              trustedIds.isEmpty
                  ? 'Pair with a device first to sync clipboards with it.'
                  : 'Copy on one device, paste on the other — works both ways. On Android, '
                      'new copies are only picked up while LAN Share is open (an Android privacy '
                      'restriction); receiving works any time the app is running.',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          if (trustedIds.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DropdownButtonFormField<String>(
                initialValue: trustedIds.contains(appState.settings.clipboardSyncDeviceId)
                    ? appState.settings.clipboardSyncDeviceId
                    : null,
                decoration: const InputDecoration(labelText: 'Sync with', border: OutlineInputBorder()),
                items: trustedIds
                    .map((id) => DropdownMenuItem(value: id, child: Text(appState.pairing.nameFor(id) ?? id)))
                    .toList(),
                onChanged: (id) {
                  if (id == null) return;
                  appState.setClipboardSync(enabled: appState.settings.clipboardSyncEnabled, deviceId: id);
                },
              ),
            ),
            SwitchListTile(
              title: const Text('Sync clipboard'),
              value: appState.settings.clipboardSyncEnabled && appState.settings.clipboardSyncDeviceId != null,
              onChanged: appState.settings.clipboardSyncDeviceId == null
                  ? null
                  : (v) => appState.setClipboardSync(enabled: v),
            ),
            if (appState.clipboardSyncError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(appState.clipboardSyncError!, style: const TextStyle(color: Colors.orange, fontSize: 12)),
              ),
          ],
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Paired devices', style: Theme.of(context).textTheme.labelLarge),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Paired devices can send you files with no prompts at all. Unpair one below to require pairing again.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          if (trustedIds.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('No paired devices yet', style: TextStyle(color: Colors.grey)),
            )
          else
            ...trustedIds.map(
              (id) => ListTile(
                title: Text(appState.pairing.nameFor(id) ?? id),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => appState.setTrusted(id, '', false),
                ),
              ),
            ),
          if (Platform.isAndroid) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: OutlinedButton.icon(
                onPressed: () => _confirmQuit(context),
                icon: const Icon(Icons.power_settings_new, color: Colors.red),
                label: const Text('Quit LAN Share', style: TextStyle(color: Colors.red)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
