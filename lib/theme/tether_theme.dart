import 'package:flutter/material.dart';

/// The full Tether palette, exposed as a [ThemeExtension] so screens can
/// reach semantic colors (ok/away/danger, muted/faint text, exact
/// surface/line tones) that don't have a clean one-to-one Material slot,
/// without hardcoding hex values or [Colors.red]/[Colors.grey] anywhere.
/// Values are lifted directly from the real Tether web app's CSS so the
/// native app matches its brand exactly rather than approximating it.
@immutable
class TetherColors extends ThemeExtension<TetherColors> {
  final Color bg;
  final Color bg2;
  final Color surface;
  final Color surface2;
  final Color line;
  final Color lineStrong;
  final Color text;
  final Color muted;
  final Color faint;
  final Color accent;
  final Color accentInk;
  final Color accentText;
  final Color accentGlow;
  final Color ok;
  final Color away;
  final Color danger;

  const TetherColors({
    required this.bg,
    required this.bg2,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.lineStrong,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentInk,
    required this.accentText,
    required this.accentGlow,
    required this.ok,
    required this.away,
    required this.danger,
  });

  static const light = TetherColors(
    bg: Color(0xFFF2F1EC),
    bg2: Color(0xFFE9E8E1),
    surface: Color(0xFFFBFBF8),
    surface2: Color(0xFFF4F3EE),
    line: Color(0x1A141612),
    lineStrong: Color(0x2E141612),
    text: Color(0xFF141512),
    muted: Color(0xFF62655E),
    faint: Color(0xFF8D9088),
    accent: Color(0xFFC8F53A),
    accentInk: Color(0xFF141512),
    accentText: Color(0xFF4A6B00),
    accentGlow: Color(0x47A0D214),
    ok: Color(0xFF17A15B),
    away: Color(0xFFD98A1B),
    danger: Color(0xFFD6452B),
  );

  static const dark = TetherColors(
    bg: Color(0xFF0A0B0C),
    bg2: Color(0xFF0F1112),
    surface: Color(0xFF141618),
    surface2: Color(0xFF1A1D1F),
    line: Color(0x14ECF0E4),
    lineStrong: Color(0x26ECF0E4),
    text: Color(0xFFECEEE6),
    muted: Color(0xFF93978E),
    faint: Color(0xFF62665F),
    accent: Color(0xFFC8F53A),
    accentInk: Color(0xFF141512),
    accentText: Color(0xFFD4FF4A),
    accentGlow: Color(0x38C8F53A),
    ok: Color(0xFF4ADE80),
    away: Color(0xFFF5B544),
    danger: Color(0xFFFF6B4F),
  );

  @override
  TetherColors copyWith({
    Color? bg,
    Color? bg2,
    Color? surface,
    Color? surface2,
    Color? line,
    Color? lineStrong,
    Color? text,
    Color? muted,
    Color? faint,
    Color? accent,
    Color? accentInk,
    Color? accentText,
    Color? accentGlow,
    Color? ok,
    Color? away,
    Color? danger,
  }) {
    return TetherColors(
      bg: bg ?? this.bg,
      bg2: bg2 ?? this.bg2,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      line: line ?? this.line,
      lineStrong: lineStrong ?? this.lineStrong,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      faint: faint ?? this.faint,
      accent: accent ?? this.accent,
      accentInk: accentInk ?? this.accentInk,
      accentText: accentText ?? this.accentText,
      accentGlow: accentGlow ?? this.accentGlow,
      ok: ok ?? this.ok,
      away: away ?? this.away,
      danger: danger ?? this.danger,
    );
  }

  @override
  TetherColors lerp(ThemeExtension<TetherColors>? other, double t) {
    if (other is! TetherColors) return this;
    return TetherColors(
      bg: Color.lerp(bg, other.bg, t)!,
      bg2: Color.lerp(bg2, other.bg2, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineStrong: Color.lerp(lineStrong, other.lineStrong, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      accentGlow: Color.lerp(accentGlow, other.accentGlow, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      away: Color.lerp(away, other.away, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

extension TetherColorsX on BuildContext {
  TetherColors get colors => Theme.of(this).extension<TetherColors>()!;
}

const _radiusSm = 8.0;
const _radius = 14.0;
const _radiusLg = 22.0;

const _easeOut = Cubic(0.22, 1, 0.36, 1);

ThemeData buildTetherTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? TetherColors.dark : TetherColors.light;
  final onAccent = c.accentInk;

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: c.accentText,
    onPrimary: brightness == Brightness.dark ? c.bg : Colors.white,
    secondary: c.accent,
    onSecondary: onAccent,
    error: c.danger,
    onError: Colors.white,
    surface: c.surface,
    onSurface: c.text,
    surfaceContainerHighest: c.surface2,
    outline: c.lineStrong,
    outlineVariant: c.line,
    inverseSurface: c.text,
    onInverseSurface: c.bg,
  );

  TextStyle sans({double size = 15, FontWeight weight = FontWeight.w400, Color? color, double? spacing}) =>
      TextStyle(fontFamily: 'Geist', fontSize: size, fontWeight: weight, color: color ?? c.text, letterSpacing: spacing);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    splashFactory: InkSparkle.splashFactory,
    fontFamily: 'Geist',
    extensions: [c],
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _TetherPageTransitionsBuilder(),
        TargetPlatform.macOS: _TetherPageTransitionsBuilder(),
        TargetPlatform.windows: _TetherPageTransitionsBuilder(),
        TargetPlatform.linux: _TetherPageTransitionsBuilder(),
        TargetPlatform.iOS: _TetherPageTransitionsBuilder(),
      },
    ),
    textTheme: TextTheme(
      headlineSmall: sans(size: 24, weight: FontWeight.w600, spacing: -0.5),
      titleLarge: sans(size: 20, weight: FontWeight.w600, spacing: -0.3),
      titleMedium: sans(size: 16, weight: FontWeight.w600, spacing: -0.1),
      titleSmall: sans(size: 14, weight: FontWeight.w600),
      bodyLarge: sans(size: 16),
      bodyMedium: sans(size: 14),
      bodySmall: sans(size: 12.5, color: c.muted),
      labelLarge: sans(size: 14, weight: FontWeight.w600),
      labelMedium: sans(size: 12, weight: FontWeight.w500, color: c.muted),
      labelSmall: sans(size: 11, weight: FontWeight.w500, color: c.faint),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: sans(size: 22, weight: FontWeight.w600, spacing: -0.4),
      iconTheme: IconThemeData(color: c.text),
      actionsIconTheme: IconThemeData(color: c.muted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.accent,
      height: 66,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => sans(
          size: 11.5,
          weight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? c.text : c.muted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(color: states.contains(WidgetState.selected) ? c.accentInk : c.muted, size: 22),
      ),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius), side: BorderSide(color: c.line)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.muted,
      textColor: c.text,
      titleTextStyle: sans(size: 15.5, weight: FontWeight.w500),
      subtitleTextStyle: sans(size: 13, color: c.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    dividerTheme: DividerThemeData(color: c.line, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: onAccent,
        disabledBackgroundColor: c.line,
        disabledForegroundColor: c.faint,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusSm + 4)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: sans(size: 14.5, weight: FontWeight.w600),
        animationDuration: const Duration(milliseconds: 160),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.lineStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusSm + 4)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: sans(size: 14.5, weight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accentText,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusSm)),
        textStyle: sans(size: 14.5, weight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.muted, highlightColor: c.line),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface2,
      hintStyle: sans(color: c.faint),
      labelStyle: sans(color: c.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(_radiusSm + 4), borderSide: BorderSide(color: c.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(_radiusSm + 4), borderSide: BorderSide(color: c.line)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(_radiusSm + 4), borderSide: BorderSide(color: c.accentText, width: 1.6)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(_radiusSm + 4), borderSide: BorderSide(color: c.danger)),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.accent : c.line,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.accentInk : c.faint,
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.accentText : c.faint,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusLg), side: BorderSide(color: c.line)),
      titleTextStyle: sans(size: 19, weight: FontWeight.w600, spacing: -0.3),
      contentTextStyle: sans(size: 14, color: c.muted),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(_radiusLg))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.text,
      contentTextStyle: sans(color: c.bg, weight: FontWeight.w500),
      actionTextColor: c.accentText,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusSm + 4)),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    ),
    bannerTheme: MaterialBannerThemeData(
      backgroundColor: c.surface2,
      contentTextStyle: sans(size: 13.5, color: c.text),
      elevation: 0,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accentText, linearTrackColor: c.line, circularTrackColor: c.line),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.accent : Colors.transparent,
      ),
      checkColor: WidgetStateProperty.all(c.accentInk),
      side: BorderSide(color: c.lineStrong, width: 1.4),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStateProperty.all(c.surface),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius), side: BorderSide(color: c.line))),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius), side: BorderSide(color: c.line)),
    ),
  );
}

/// A subtle fade-through-and-rise transition used for every route push —
/// smoother and calmer than the platform default, and identical across
/// platforms so desktop and mobile feel like the same product.
class _TetherPageTransitionsBuilder extends PageTransitionsBuilder {
  const _TetherPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: _easeOut, reverseCurve: _easeOut.flipped);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }
}
