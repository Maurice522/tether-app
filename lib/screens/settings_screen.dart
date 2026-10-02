import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/tether_theme.dart';
import '../util/network_info.dart';
import '../util/reveal.dart';
import '../util/reveal_feedback.dart';
import 'qr_show_screen.dart';

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
        title: const Text('Quit Tether?'),
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
    final colors = context.colors;
    final trustedIds = appState.pairing.trustedIds;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SectionLabel('This device', colors),
          _SettingsCard(
            colors: colors,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(labelText: 'Device name'),
                        onSubmitted: (_) => _saveName(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(onPressed: _saveName, child: const Text('Save')),
                  ],
                ),
              ),
              _divider(colors),
              if (_ipAddresses.isEmpty)
                const _Row(title: 'IP address', subtitle: 'Looking it up…')
              else
                for (var i = 0; i < _ipAddresses.length; i++) ...[
                  _Row(
                    title: _ipAddresses.length > 1 ? 'IP address ${i + 1}' : 'IP address',
                    subtitle: _ipAddresses[i],
                    monoSubtitle: true,
                    trailing: IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 19),
                      tooltip: 'Copy',
                      onPressed: () => _copyIp(_ipAddresses[i]),
                    ),
                  ),
                  if (i != _ipAddresses.length - 1) _divider(colors),
                ],
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Text(
                  'Type this into "Add device by IP" on another device if it isn\'t showing up automatically.',
                  style: TextStyle(color: colors.faint, fontSize: 12),
                ),
              ),
              _divider(colors),
              _Row(
                title: 'My QR Code',
                subtitle: 'Let another device scan this to pair',
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrShowScreen())),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _SectionLabel('Shared folder', colors),
          _SettingsCard(
            colors: colors,
            children: [
              _Row(
                title: 'Download folder',
                subtitle: appState.settings.downloadDir,
                monoSubtitle: true,
                trailing: IconButton(
                  icon: const Icon(Icons.folder_open_rounded, size: 19),
                  tooltip: 'Reveal',
                  onPressed: () => revealWithFeedback(context, () => openFolder(appState.settings.downloadDir)),
                ),
                onTap: () async {
                  final path = await FilePicker.getDirectoryPath();
                  if (path != null) await appState.updateDownloadDir(path);
                },
              ),
            ],
          ),
          const SizedBox(height: 22),
          _SectionLabel('Theme', colors),
          _SettingsCard(
            colors: colors,
            children: [
              RadioGroup<ThemeMode>(
                groupValue: appState.themeMode,
                onChanged: (v) => appState.updateThemeMode(v!),
                child: Column(
                  children: [
                    const RadioListTile<ThemeMode>(title: Text('System'), value: ThemeMode.system),
                    _divider(colors),
                    const RadioListTile<ThemeMode>(title: Text('Light'), value: ThemeMode.light),
                    _divider(colors),
                    const RadioListTile<ThemeMode>(title: Text('Dark'), value: ThemeMode.dark),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _SectionLabel('Clipboard sync', colors),
          _SettingsCard(
            colors: colors,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(14, 12, 14, trustedIds.isEmpty ? 12 : 0),
                child: Text(
                  trustedIds.isEmpty
                      ? 'Pair with a device first to sync clipboards with it.'
                      : 'Copy on one device, paste on the other — works both ways. On Android, '
                          'new copies are only picked up while Tether is open (an Android privacy '
                          'restriction); receiving works any time the app is running.',
                  style: TextStyle(color: colors.muted, fontSize: 12.5, height: 1.4),
                ),
              ),
              if (trustedIds.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                  child: DropdownButtonFormField<String>(
                    initialValue: trustedIds.contains(appState.settings.clipboardSyncDeviceId)
                        ? appState.settings.clipboardSyncDeviceId
                        : null,
                    decoration: const InputDecoration(labelText: 'Sync with'),
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
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Row(
                      children: [
                        Icon(Icons.wifi_off_rounded, size: 15, color: colors.away),
                        const SizedBox(width: 6),
                        Expanded(child: Text(appState.clipboardSyncError!, style: TextStyle(color: colors.away, fontSize: 12.5))),
                      ],
                    ),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 22),
          _SectionLabel('Paired devices', colors),
          _SettingsCard(
            colors: colors,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(14, 12, 14, trustedIds.isEmpty ? 12 : 4),
                child: Text(
                  'Paired devices can send you files with no prompts at all. Unpair one below to require pairing again.',
                  style: TextStyle(color: colors.muted, fontSize: 12.5, height: 1.4),
                ),
              ),
              if (trustedIds.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: Text('No paired devices yet', style: TextStyle(color: colors.faint)),
                )
              else
                for (var i = 0; i < trustedIds.length; i++) ...[
                  _Row(
                    title: appState.pairing.nameFor(trustedIds[i]) ?? trustedIds[i],
                    trailing: IconButton(
                      icon: const Icon(Icons.close_rounded, size: 19),
                      onPressed: () => appState.setTrusted(trustedIds[i], '', false),
                    ),
                  ),
                  if (i != trustedIds.length - 1) _divider(colors),
                ],
            ],
          ),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 32),
            OutlinedButton.icon(
              onPressed: () => _confirmQuit(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.danger,
                side: BorderSide(color: colors.danger.withValues(alpha: 0.4)),
              ),
              icon: const Icon(Icons.power_settings_new_rounded),
              label: const Text('Quit Tether'),
            ),
          ],
        ],
      ),
    );
  }
}

Widget _divider(TetherColors colors) => Divider(height: 1, indent: 14, endIndent: 14, color: colors.line);

class _SectionLabel extends StatelessWidget {
  final String title;
  final TetherColors colors;
  const _SectionLabel(this.title, this.colors);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: colors.faint),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final TetherColors colors;
  final List<Widget> children;
  const _SettingsCard({required this.colors, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool monoSubtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Row({required this.title, this.subtitle, this.monoSubtitle = false, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: monoSubtitle ? const TextStyle(fontFamily: 'Geist Mono', fontSize: 12.5) : null),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
