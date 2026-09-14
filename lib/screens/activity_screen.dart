import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'widgets/transfer_tile.dart';

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final active = appState.activeTransfers.values.toList();
    final history = appState.completedTransfers;

    if (active.isEmpty && history.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Activity')),
        body: Center(
          child: Text(
            'No transfers yet',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          if (history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear history',
              onPressed: () => appState.clearHistory(),
            ),
        ],
      ),
      body: ListView(
        children: [
          if (active.isNotEmpty) ...[
            const _SectionHeader('In progress'),
            ...active.map((r) => TransferTile(record: r)),
            const Divider(height: 1),
          ],
          if (history.isNotEmpty) ...[
            const _SectionHeader('History'),
            ...history.map((r) => TransferTile(record: r)),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
