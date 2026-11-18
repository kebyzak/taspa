import 'package:flutter/material.dart';

import 'phosphor.dart';
import '../features/catalog/presentation/artwork.dart';

const canvasColor = Color(0xff141416);
const surfaceColor = Color(0xff1d1c1f);
const pressedColor = Color(0xff2b292d);
const inkColor = Color(0xfff3eee8);
const mutedColor = Color(0xffb2aaa8);
const hairlineColor = Color(0xff39363b);
const coralColor = Color(0xffdb806f);
const onCoralColor = Color(0xff1c1414);
const selectedColor = Color(0xff382725);

const _sans = 'Instrument Sans';
const _label = TextStyle(
  fontFamily: _sans,
  fontSize: 15,
  fontWeight: FontWeight.w600,
);
const _corners = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(12)),
);
// Selected chips are ivory pills, so their label flips to graphite.
const _chipLabel = WidgetStateColor.fromMap({
  WidgetState.selected: canvasColor,
  WidgetState.any: inkColor,
});
const _field = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(12)),
  borderSide: BorderSide.none,
);

ThemeData taspaTheme() {
  // secondary/tertiary set explicitly so no Material default (teal) leaks into chips or toggles.
  const scheme = ColorScheme.dark(
    primary: coralColor,
    onPrimary: onCoralColor,
    secondary: coralColor,
    onSecondary: onCoralColor,
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
  final theme = ThemeData(
    colorScheme: scheme,
    fontFamily: _sans,
    scaffoldBackgroundColor: canvasColor,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    dividerTheme: const DividerThemeData(color: hairlineColor, space: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: canvasColor,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 16,
      titleTextStyle: TextStyle(
        fontFamily: _sans,
        fontSize: 24,
        height: 1.167,
        fontWeight: FontWeight.w600,
        color: inkColor,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surfaceColor,
      surfaceTintColor: Colors.transparent,
      indicatorColor: selectedColor,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: _sans,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? inkColor : mutedColor,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? coralColor
              : mutedColor,
        ),
      ),
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(48, 52)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 20)),
        shape: WidgetStatePropertyAll(_corners),
        textStyle: WidgetStatePropertyAll(_label),
      ),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(48, 52)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 20)),
        foregroundColor: WidgetStatePropertyAll(inkColor),
        side: WidgetStatePropertyAll(BorderSide(color: hairlineColor)),
        shape: WidgetStatePropertyAll(_corners),
        textStyle: WidgetStatePropertyAll(_label),
      ),
    ),
    // Quiet text actions are neutral; coral is reserved for primary fills and state.
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        foregroundColor: WidgetStatePropertyAll(inkColor),
        shape: WidgetStatePropertyAll(_corners),
        textStyle: WidgetStatePropertyAll(_label),
      ),
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(inkColor)),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: surfaceColor,
      selectedColor: inkColor,
      side: BorderSide.none,
      shape: StadiumBorder(),
      showCheckmark: false,
      labelStyle: TextStyle(
        fontFamily: _sans,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: _chipLabel,
      ),
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    cardTheme: const CardThemeData(
      color: surfaceColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: surfaceColor,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: mutedColor,
      shape: _corners,
      titleTextStyle: TextStyle(
        fontFamily: _sans,
        fontSize: 16,
        height: 1.375,
        fontWeight: FontWeight.w600,
        color: inkColor,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: _sans,
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: pressedColor,
      surfaceTintColor: Colors.transparent,
      shape: _corners,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: pressedColor,
      contentTextStyle: TextStyle(
        fontFamily: _sans,
        fontSize: 15,
        color: inkColor,
      ),
      actionTextColor: coralColor,
      shape: _corners,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: coralColor,
      linearTrackColor: Color(0xff49434a),
      linearMinHeight: 4,
      borderRadius: BorderRadius.all(Radius.circular(2)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: surfaceColor,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(color: mutedColor),
      prefixIconColor: mutedColor,
      border: _field,
      enabledBorder: _field,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
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

/// Section title with an optional "See all" chevron, used above shelves and lists.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    super.key,
    this.onMore,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 4, 8),
  });
  final String title;
  final VoidCallback? onMore;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
          ),
          ?trailing,
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              style: TextButton.styleFrom(foregroundColor: mutedColor),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('See all'),
                  Icon(PhosphorIconsRegular.caretRight, size: 20),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// Poster with title and caption below; the shared unit for shelves and grids.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.poster,
    required this.title,
    this.caption,
    this.badge,
    required this.onTap,
  });
  final String? poster;
  final String title;
  final String? caption;
  final String? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: [title, ?caption].join(', '),
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Artwork(poster),
                if (badge case final text?)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: canvasColor.withValues(alpha: .85),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            PhosphorIconsFill.star,
                            size: 14,
                            color: coralColor,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            text,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              height: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (caption case final text? when text.isNotEmpty)
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    ),
  );
}

/// Horizontal carousel of fixed-width items; shows placeholder posters while [children] is null.
class Shelf extends StatelessWidget {
  const Shelf({super.key, required this.children, this.itemWidth = 112});
  final List<Widget>? children;
  final double itemWidth;

  @override
  Widget build(BuildContext context) {
    final items =
        children ??
        List.filled(
          4,
          AspectRatio(
            aspectRatio: 2 / 3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        );
    return SizedBox(
      height: itemWidth * 1.5 + 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) =>
            SizedBox(width: itemWidth, child: items[index]),
      ),
    );
  }
}

/// Large icon-over-label action, used for the main tracking controls on detail pages.
class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: active,
    child: Material(
      color: active ? selectedColor : surfaceColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: onTap == null
                    ? hairlineColor
                    : active
                    ? coralColor
                    : inkColor,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: onTap == null ? mutedColor : inkColor,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Circular initial avatar for people without a loaded photo.
class Avatar extends StatelessWidget {
  const Avatar(this.handle, {super.key, this.size = 32});
  final String handle;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      color: selectedColor,
    ),
    child: Text(
      handle.isEmpty ? '?' : handle[0].toUpperCase(),
      style: TextStyle(
        fontFamily: 'Instrument Serif',
        fontSize: size * .5,
        color: coralColor,
      ),
    ),
  );
}

/// Star glyph plus a 1–10 score.
class StarScore extends StatelessWidget {
  const StarScore(this.score, {super.key, this.large = false});
  final int score;
  final bool large;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$score of 10',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(PhosphorIconsFill.star, size: large ? 22 : 18, color: coralColor),
        const SizedBox(width: 2),
        Text(
          '$score',
          style: TextStyle(
            fontSize: large ? 18 : 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// Small status line (offline, pending, errors) with an optional action, kept on one compact row.
class InlineNotice extends StatelessWidget {
  const InlineNotice(
    this.text, {
    super.key,
    this.icon = PhosphorIconsRegular.info,
    this.action,
    this.onAction,
  });
  final String text;
  final IconData icon;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.only(left: 12),
    decoration: BoxDecoration(
      color: surfaceColor,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: mutedColor),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                text,
                style: const TextStyle(fontSize: 14, color: mutedColor),
              ),
            ),
          ),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
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
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
    child: Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            color: surfaceColor,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: coralColor, size: 32),
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
            style: const TextStyle(
              fontSize: 15,
              height: 1.47,
              color: mutedColor,
            ),
          ),
        ),
        if (action != null) ...[const SizedBox(height: 24), action!],
        ?secondary,
      ],
    ),
  );
}
