import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'screens/home_screen.dart';
import 'services/desktop_window_service.dart';
import 'state/app_state.dart';
import 'theme/tether_theme.dart';
import 'util/send_flow.dart';

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
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<List<SharedMediaFile>>? _shareIntentSub;

  @override
  void initState() {
    super.initState();
    _appState.init();
    // Android only: no ios/ directory exists in this project, and the
    // plugin's default (mobile) implementation has no desktop backend to
    // route these calls to.
    if (Platform.isAndroid) _initShareIntent();
  }

  void _initShareIntent() {
    // Cold start: the app was launched BY a share, so the shared files are
    // already waiting rather than arriving as a later stream event.
    ReceiveSharingIntent.instance.getInitialMedia().then(_handleSharedMedia);
    _shareIntentSub = ReceiveSharingIntent.instance.getMediaStream().listen(_handleSharedMedia);
  }

  void _handleSharedMedia(List<SharedMediaFile> media) {
    if (media.isEmpty) return;
    ReceiveSharingIntent.instance.reset();
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    pickTargetDeviceAndSend(context, media.map((m) => File(m.path)).toList());
  }

  @override
  void dispose() {
    _shareIntentSub?.cancel();
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: _appState,
      // Selector (not Consumer) so this only rebuilds — and rebuilds both
      // light/dark ThemeData from scratch — when themeMode or ready
      // actually change, not on every AppState.notifyListeners() call
      // (e.g. once per chunk during a transfer's progress updates).
      child: Selector<AppState, (ThemeMode, bool)>(
        selector: (_, appState) => (appState.themeMode, appState.ready),
        builder: (context, state, _) {
          final (themeMode, ready) = state;
          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: 'Tether',
            debugShowCheckedModeBanner: false,
            themeMode: themeMode,
            theme: buildTetherTheme(Brightness.light),
            darkTheme: buildTetherTheme(Brightness.dark),
            home: ready ? const HomeScreen() : const _LoadingSplash(),
          );
        },
      ),
    );
  }
}

/// Shown only until [AppState.init] finishes. A plain [Builder] so
/// `Theme.of(context)` resolves against whichever of MaterialApp's
/// `theme`/`darkTheme` it picked for the current system/user preference —
/// hardcoding dark colors here would flash a dark splash to a user on
/// light mode for the instant before `ready` flips true.
class _LoadingSplash extends StatelessWidget {
  const _LoadingSplash();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).brightness == Brightness.dark ? TetherColors.dark : TetherColors.light;
    return Container(
      color: colors.bg,
      child: Center(child: CircularProgressIndicator(color: colors.accentText)),
    );
  }
}
