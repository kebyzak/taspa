import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../../core/backend_config.dart';
import '../../auth/auth_cubit.dart';
import '../../social/data/social_repository.dart';
import '../data/catalog_repository.dart';
import 'artwork.dart';

/// Short public links: `<base>/m/<tmdb id>` or `/s/<tmdb id>`. Set SHARE_URL once a short domain proxies to the share function.
const _shareBase = String.fromEnvironment('SHARE_URL');

String titleLink(CatalogTitle title) =>
    '${_shareBase.isEmpty ? '$backendUrl/functions/v1/share' : _shareBase}'
    '/${title.kind == MediaKind.movie ? 'm' : 's'}/${title.tmdbId}';

/// Previews a 4:5 poster card for [title], then shares it as a PNG with the title link as the caption.
Future<void> shareTitle(BuildContext context, CatalogTitle title) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (context) => _ShareSheet(title),
    );

class _ShareSheet extends StatefulWidget {
  const _ShareSheet(this.title);
  final CatalogTitle title;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _card = GlobalKey();
  bool _busy = false;
  String? _error;
  num? _score;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadScore().then((score) {
      if (mounted) {
        setState(() {
          _score = score;
          _loading = false;
        });
      }
    });
  }

  String get _link => titleLink(widget.title);

  /// The viewer's own score, if signed in and rated; the card just leaves it out otherwise.
  Future<num?> _loadScore() async {
    final id = widget.title.id;
    if (id == null ||
        context.read<AccountCubit>().state.phase != AccountPhase.ready) {
      return null;
    }
    try {
      final opinion = await context.read<SocialRepository>().opinions(id, null);
      return (opinion?['my_rating'] as Map?)?['score'] as num?;
    } on Exception {
      return null;
    }
  }

  Future<void> _share() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final boundary =
          _card.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      // 360×450 logical → 1080×1350, the 4:5 size feeds and stories expect.
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(png!.buffer.asUint8List(), mimeType: 'image/png'),
          ],
          fileNameOverrides: ['taspa-${widget.title.tmdbId}.png'],
          text: '${widget.title.name}\n$_link',
        ),
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (error, stack) {
      // Shown in the sheet: a SnackBar would sit behind it. Any failure (plugin, render) must surface, not vanish.
      debugPrint('Share failed: $error\n$stack');
      if (mounted) setState(() => _error = 'Could not share. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .6,
            ),
            child: AspectRatio(
              aspectRatio: 4 / 5,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: FittedBox(
                  child: RepaintBoundary(
                    key: _card,
                    child: _TitleCard(widget.title, score: _score),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error case final error?) ...[
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy || _loading ? null : _share,
              icon: const Icon(PhosphorIconsRegular.export),
              label: const Text('Share'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _TitleCard extends StatelessWidget {
  const _TitleCard(this.title, {this.score});
  final CatalogTitle title;
  final num? score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rating = title.details['rating'] as Map<String, dynamic>?;
    final runtime = switch (title.runtime) {
      final m? when m >= 60 => '${m ~/ 60}h ${m % 60}m',
      final m? => '$m min',
      null => null,
    };
    final facts = [
      title.caption,
      ?runtime,
      ...title.genres.take(2),
    ].join(' · ');
    return SizedBox(
      width: 360,
      height: 450,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: canvasColor),
          // The poster itself, blurred and dimmed, as a backdrop in its own colours.
          Opacity(
            opacity: .45,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Artwork(title.poster, radius: 0),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [.35, 1],
                colors: [Color(0x00141416), canvasColor],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
            child: Column(
              children: [
                Container(
                  width: 152,
                  height: 228,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x99000000),
                        blurRadius: 32,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Artwork(title.poster, radius: 12),
                ),
                const SizedBox(height: 20),
                Text(
                  title.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontSize: 30,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  facts,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: mutedColor),
                ),
                const Spacer(),
                Row(
                  children: [
                    if (rating?['value'] case final num value)
                      Row(
                        children: [
                          const Icon(
                            PhosphorIconsFill.star,
                            color: coralColor,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            value.toStringAsFixed(1),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: inkColor,
                              fontFeatures: [ui.FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            rating?['source'] == 'imdb' ? 'IMDb' : 'TMDB',
                            style: const TextStyle(
                              fontSize: 13,
                              color: mutedColor,
                            ),
                          ),
                        ],
                      ),
                    if (score case final score?) ...[
                      const SizedBox(width: 16),
                      ScoreBadge(score),
                      const SizedBox(width: 6),
                      const Text(
                        'My score',
                        style: TextStyle(fontSize: 13, color: mutedColor),
                      ),
                    ],
                    const Spacer(),
                    SvgPicture.asset(
                      'assets/brand/wordmark_ivory.svg',
                      width: 64,
                      excludeFromSemantics: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
