import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/pairing_request.dart';
import '../models/transfer.dart';
import '../state/app_state.dart';
import 'activity_screen.dart';
import 'devices_screen.dart';
import 'settings_screen.dart';
import 'widgets/incoming_pair_dialog.dart';
import 'widgets/incoming_transfer_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  IncomingTransferRequest? _dialogShownFor;
  IncomingPairRequest? _pairDialogShownFor;

  static const _screens = [DevicesScreen(), ActivityScreen(), SettingsScreen()];

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final next = appState.pendingRequests.isEmpty ? null : appState.pendingRequests.first;
    final nextPair = appState.pendingPairRequests.isEmpty ? null : appState.pendingPairRequests.first;

    if (next != null && next != _dialogShownFor) {
      _dialogShownFor = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => IncomingTransferDialog(request: next),
        ).then((_) => _dialogShownFor = null);
      });
    }

    if (nextPair != null && nextPair != _pairDialogShownFor) {
      _pairDialogShownFor = nextPair;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => IncomingPairDialog(request: nextPair),
        ).then((_) => _pairDialogShownFor = null);
      });
    }

    return Scaffold(
      body: _screens[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.devices_outlined), selectedIcon: Icon(Icons.devices), label: 'Devices'),
          NavigationDestination(icon: Icon(Icons.swap_vert_outlined), selectedIcon: Icon(Icons.swap_vert), label: 'Activity'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
