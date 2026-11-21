import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'phosphor.dart';
import '../features/catalog/presentation/artwork.dart';
import '../features/social/data/social_repository.dart';

const canvasColor = Color(0xff12161c);
const surfaceColor = Color(0xff1c222b);
const pressedColor = Color(0xff262e39);
const inkColor = Color(0xffedf1f5);
const mutedColor = Color(0xff9aa4b0);
const hairlineColor = Color(0xff2e3640);
const coralColor = Color(0xff7cc4e8);
const onCoralColor = Color(0xff0e1a22);
const selectedColor = Color(0xff1d3240);

const _sans = 'Noto Sans';
const _label = TextStyle(
  fontFamily: _sans,
  fontSize: 15,
  fontWeight: FontWeight.w600,
);
const _corners = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(12)),
);
const _chipLabel = WidgetStateColor.fromMap({
  WidgetState.selected: onCoralColor,
  WidgetState.any: inkColor,
});
const _field = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(12)),
  borderSide: BorderSide.none,
);

ThemeData taspaTheme() {
  const scheme = ColorScheme.dark(
    primary: coralColor,
    onPrimary: onCoralColor,
    secondary: coralColor,
    onSecondary: onCoralColor,
    secondaryContainer: coralColor,
    onSecondaryContainer: onCoralColor,
    tertiary: coralColor,
    surface: canvasColor,
    surfaceContainerLowest: canvasColor,
    surfaceContainerLow: surfaceColor,
    surfaceContainer: surfaceColor,
    surfaceContainerHigh: pressedColor,
    surfaceContainerHighest: pressedColor,
    onSurface: inkColor,
    onSurfaceVariant: mutedColor,
    outline: Color(0xff7f8895),
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
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (context) =>
          const Icon(PhosphorIconsRegular.arrowLeft),
      closeButtonIconBuilder: (context) => const Icon(PhosphorIconsRegular.x),
    ),
    segmentedButtonTheme: const SegmentedButtonThemeData(
      selectedIcon: Icon(PhosphorIconsRegular.check),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: canvasColor,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
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
      selectedColor: coralColor,
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
      linearTrackColor: Color(0xff3a4350),
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
        fontFamily: 'Gloock',
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

class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.poster,
    required this.title,
    this.caption,
    this.score,
    this.own,
    required this.onTap,
  });

  final String? poster;
  final String title;
  final String? caption;
  final num? score;

  /// (kind, tmdbId) of a catalog title: the viewer's own score is looked up and shown like in the profile.
  final (String, int)? own;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (own case (final kind, final tmdbId)? when score == null) {
      final social = context.read<SocialRepository>()..wantScore(tmdbId);
      return ValueListenableBuilder(
        valueListenable: social.myScores,
        builder: (context, scores, _) => PosterCard(
          poster: poster,
          title: title,
          caption: caption,
          score: scores['$kind:$tmdbId'],
          onTap: onTap,
        ),
      );
    }
    return _card(context);
  }

  Widget _card(BuildContext context) => Semantics(
    button: true,
    label: [
      title,
      ?caption,
      if (score != null) 'rated ${scoreText(score!)} of 10',
    ].join(', '),
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
                if (score case final score?)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: ScoreBadge(score, corner: true),
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

class Avatar extends StatelessWidget {
  const Avatar(this.handle, {super.key, this.size = 32, this.userId});

  final String handle;
  final double size;
  final String? userId;

  @override
  Widget build(BuildContext context) {
    final initials = Container(
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
          fontFamily: 'Gloock',
          fontSize: size * .5,
          color: coralColor,
        ),
      ),
    );
    final id = userId;
    if (id == null) return initials;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          avatarUrl(id),
          headers: context.read<SocialRepository>().avatarHeaders,
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          frameBuilder: (context, child, frame, sync) =>
              frame == null ? initials : child,
          errorBuilder: (_, _, _) => initials,
        ),
      ),
    );
  }
}

String scoreText(num score) =>
    score % 1 == 0 ? '${score.toInt()}' : score.toStringAsFixed(1);

class ScoreBadge extends StatelessWidget {
  const ScoreBadge(this.score, {super.key, this.corner = false});

  final num score;
  final bool corner;

  @override
  Widget build(BuildContext context) => Container(
    height: 22,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: BoxDecoration(
      color: coralColor.withValues(alpha: .75),
      borderRadius: corner
          ? const BorderRadius.only(
              topRight: Radius.circular(8),
              bottomLeft: Radius.circular(8),
            )
          : BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(PhosphorIconsFill.star, size: 12, color: onCoralColor),
        const SizedBox(width: 2),
        Text(
          scoreText(score),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: onCoralColor,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

class StarScore extends StatelessWidget {
  const StarScore(this.score, {super.key, this.large = false});

  final num score;
  final bool large;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${scoreText(score)} of 10',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(PhosphorIconsFill.star, size: large ? 22 : 18, color: coralColor),
        const SizedBox(width: 2),
        Text(
          scoreText(score),
          style: TextStyle(
            fontSize: large ? 18 : 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

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

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String readableDate(DateTime value) {
  final day = '${_monthNames[value.month - 1]} ${value.day}';
  return value.year == DateTime.now().year ? day : '$day, ${value.year}';
}

String readableDay(String day) {
  final value = DateTime.tryParse(day);
  return value == null ? day : readableDate(value);
}
