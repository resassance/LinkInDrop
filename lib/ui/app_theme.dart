import 'package:flutter/material.dart';

final _lightTheme = _createTheme(Brightness.light);
final _darkTheme = _createTheme(Brightness.dark);

ThemeData linkInDropTheme(Brightness brightness) => brightness == Brightness.dark ? _darkTheme : _lightTheme;

ThemeData _createTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = ThemeData(useMaterial3: true, brightness: brightness);
  final colors = ColorScheme.fromSeed(seedColor: const Color(0xff2457ff), brightness: brightness).copyWith(
    primary: Color(dark ? 0xff7299ff : 0xff2457ff),
    onPrimary: Color(dark ? 0xff08152f : 0xffffffff),
    surface: Color(dark ? 0xff182233 : 0xffffffff),
    onSurface: Color(dark ? 0xfff2f5fc : 0xff101627),
    onSurfaceVariant: Color(dark ? 0xffb2bfd3 : 0xff616e85),
    outlineVariant: Color(dark ? 0xff344156 : 0xffdce2ec));
  return base.copyWith(
    scaffoldBackgroundColor: Color(dark ? 0xff101827 : 0xfff7f9fe),
    colorScheme: colors,
    textTheme: base.textTheme.apply(bodyColor: colors.onSurface, displayColor: colors.onSurface).copyWith(
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 15, color: colors.onSurface),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16, color: colors.onSurface)),
    appBarTheme: AppBarTheme(backgroundColor: Color(dark ? 0xff101827 : 0xfff7f9fe),
      foregroundColor: colors.onSurface, surfaceTintColor: Colors.transparent, elevation: 0),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: colors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: colors.outlineVariant))),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      minimumSize: const Size(48, 48), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48), side: BorderSide(color: colors.outlineVariant), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
    popupMenuTheme: PopupMenuThemeData(color: colors.surface, surfaceTintColor: Colors.transparent, elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.outlineVariant))),
    dialogTheme: DialogThemeData(backgroundColor: colors.surface, surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: colors.surface, surfaceTintColor: Colors.transparent,
      showDragHandle: true, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24)))),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: colors.surface,
      indicatorColor: colors.primary.withValues(alpha: 0.12), height: 72),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating));
}
