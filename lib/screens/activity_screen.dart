import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/tether_theme.dart';
import 'widgets/transfer_tile.dart';

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final colors = context.colors;
    final active = appState.activeTransfers.values.toList();
    final history = appState.completedTransfers;

    if (active.isEmpty && history.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Activity')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(color: colors.surface2, shape: BoxShape.circle),
                child: Icon(Icons.swap_vert_rounded, size: 34, color: colors.faint),
              ),
              const SizedBox(height: 20),
              Text('No transfers yet', style: Theme.of(context).textTheme.titleMedium),
            ],
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
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (active.isNotEmpty) ...[
            _SectionHeader('In progress', colors),
            ...active.map((r) => TransferTile(record: r)),
            const SizedBox(height: 8),
          ],
          if (history.isNotEmpty) ...[
            _SectionHeader('History', colors),
            ...history.map((r) => TransferTile(record: r)),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final TetherColors colors;
  const _SectionHeader(this.title, this.colors);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: colors.faint),
      ),
    );
  }
}
