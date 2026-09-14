import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: context.read<AppState>().settings.deviceName);
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
          ListTile(
            title: const Text('Download folder'),
            subtitle: Text(appState.settings.downloadDir),
            trailing: const Icon(Icons.folder_open),
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
        ],
      ),
    );
  }
}
