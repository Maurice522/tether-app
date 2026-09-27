import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/desktop_window_service.dart';
import 'state/app_state.dart';
import 'theme/tether_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final desktopWindow = DesktopWindowService();
  await desktopWindow.init();
  runApp(TetherApp(desktopWindow: desktopWindow));
}

class TetherApp extends StatefulWidget {
  final DesktopWindowService desktopWindow;

  const TetherApp({super.key, required this.desktopWindow});

  @override
  State<TetherApp> createState() => _TetherAppState();
}

class _TetherAppState extends State<TetherApp> {
  late final AppState _appState = AppState(desktopWindow: widget.desktopWindow);

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
            title: 'Tether',
            debugShowCheckedModeBanner: false,
            themeMode: appState.themeMode,
            theme: buildTetherTheme(Brightness.light),
            darkTheme: buildTetherTheme(Brightness.dark),
            home: appState.ready
                ? const HomeScreen()
                : Container(
                    color: TetherColors.dark.bg,
                    child: Center(
                      child: CircularProgressIndicator(color: TetherColors.dark.accentText),
                    ),
                  ),
          );
        },
      ),
    );
  }
}
