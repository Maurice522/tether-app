import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'state/app_state.dart';

void main() {
  runApp(const LanShareApp());
}

class LanShareApp extends StatefulWidget {
  const LanShareApp({super.key});

  @override
  State<LanShareApp> createState() => _LanShareAppState();
}

class _LanShareAppState extends State<LanShareApp> {
  final AppState _appState = AppState();

  @override
  void initState() {
    super.initState();
    _appState.init();
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: _appState,
      child: Consumer<AppState>(
        builder: (context, appState, _) {
          return MaterialApp(
            title: 'LAN Share',
            debugShowCheckedModeBanner: false,
            themeMode: appState.themeMode,
            theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
            ),
            home: appState.ready
                ? const HomeScreen()
                : const Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        },
      ),
    );
  }
}
