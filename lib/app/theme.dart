import 'package:flutter/material.dart';

const canvasColor = Color(0xff141416);
const surfaceColor = Color(0xff1d1c1f);
const pressedColor = Color(0xff2b292d);
const inkColor = Color(0xfff3eee8);
const mutedColor = Color(0xffb2aaa8);
const hairlineColor = Color(0xff39363b);
const coralColor = Color(0xffdb806f);
const selectedColor = Color(0xff382725);

ThemeData taspaTheme() {
  // secondary/tertiary set explicitly so no Material default (teal) leaks into chips or toggles.
  final scheme = const ColorScheme.dark(
    primary: coralColor,
    onPrimary: Color(0xff1c1414),
    secondary: coralColor,
    onSecondary: Color(0xff1c1414),
    secondaryContainer: selectedColor,
    onSecondaryContainer: inkColor,
    tertiary: coralColor,
    surface: canvasColor,
    surfaceContainerLowest: canvasColor,
    surfaceContainerLow: surfaceColor,
    surfaceContainer: surfaceColor,
    surfaceContainerHigh: pressedColor,
    surfaceContainerHighest: pressedColor,
    onSurface: inkColor,
    onSurfaceVariant: mutedColor,
    outline: Color(0xff82797e),
    outlineVariant: hairlineColor,
    error: Color(0xffffaaa7),
  );
  const corners = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(8)),
  );
  const label = TextStyle(
    fontFamily: 'Instrument Sans',
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );
  final theme = ThemeData(
    colorScheme: scheme,
    fontFamily: 'Instrument Sans',
    scaffoldBackgroundColor: canvasColor,
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: const DividerThemeData(color: hairlineColor, space: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: canvasColor,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 16,
      titleTextStyle: TextStyle(
        fontFamily: 'Instrument Sans',
        fontSize: 24,
        height: 1.167,
        fontWeight: FontWeight.w600,
        color: inkColor,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surfaceColor,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: 'Instrument Sans',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? inkColor : mutedColor,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected) ? coralColor : mutedColor,
        ),
      ),
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        shape: WidgetStatePropertyAll(corners),
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        foregroundColor: WidgetStatePropertyAll(inkColor),
        side: WidgetStatePropertyAll(BorderSide(color: hairlineColor)),
        shape: WidgetStatePropertyAll(corners),
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    // Quiet text actions are neutral; coral is reserved for primary fills and state.
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        foregroundColor: WidgetStatePropertyAll(inkColor),
        shape: WidgetStatePropertyAll(corners),
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(inkColor)),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: canvasColor,
      selectedColor: selectedColor,
      side: BorderSide(color: hairlineColor),
      shape: corners,
      showCheckmark: false,
      labelStyle: TextStyle(
        fontFamily: 'Instrument Sans',
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: inkColor,
      ),
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: mutedColor,
      titleTextStyle: TextStyle(
        fontFamily: 'Instrument Sans',
        fontSize: 16,
        height: 1.375,
        fontWeight: FontWeight.w600,
        color: inkColor,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: 'Instrument Sans',
        fontSize: 13,
        height: 1.54,
        color: mutedColor,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: surfaceColor,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: pressedColor,
      surfaceTintColor: Colors.transparent,
      shape: corners,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: pressedColor,
      contentTextStyle: TextStyle(
        fontFamily: 'Instrument Sans',
        fontSize: 15,
        color: inkColor,
      ),
      actionTextColor: coralColor,
      shape: corners,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: coralColor,
      linearTrackColor: Color(0xff49434a),
      linearMinHeight: 2,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: surfaceColor,
      hintStyle: TextStyle(color: mutedColor),
      prefixIconColor: mutedColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: coralColor),
      ),
    ),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      displaySmall: const TextStyle(
        fontFamily: 'Instrument Serif',
        fontSize: 32,
        height: 1.125,
        color: inkColor,
      ),
      headlineSmall: const TextStyle(
        fontSize: 24,
        height: 1.167,
        fontWeight: FontWeight.w600,
        color: inkColor,
      ),
      titleLarge: const TextStyle(
        fontSize: 20,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: inkColor,
      ),
      titleMedium: const TextStyle(
        fontSize: 16,
        height: 1.375,
        fontWeight: FontWeight.w600,
        color: inkColor,
      ),
      bodyLarge: const TextStyle(fontSize: 16, height: 1.5, color: inkColor),
      bodyMedium: const TextStyle(fontSize: 16, height: 1.5, color: inkColor),
      bodySmall: const TextStyle(fontSize: 13, height: 1.54, color: mutedColor),
      labelLarge: const TextStyle(
        fontSize: 15,
        height: 1.4,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// Shared empty state: a reason and one action, centered in the free space.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.secondary,
  });
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 64),
    child: Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            color: surfaceColor,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: mutedColor, size: 28),
        ),
        const SizedBox(height: 24),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, height: 1.47, color: mutedColor),
          ),
        ),
        if (action != null) ...[const SizedBox(height: 24), action!],
        ?secondary,
      ],
    ),
  );
}
