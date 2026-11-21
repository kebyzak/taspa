import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../auth/auth_cubit.dart';
import '../../../core/backend_config.dart';
import '../../../core/offline_store.dart';
import '../data/social_repository.dart';

const audienceLabels = {
  'only_me': 'Only me',
  'followers': 'Followers',
  'public': 'Public',
};

class FollowedRecommendations extends StatelessWidget {
  const FollowedRecommendations({super.key, this.titleId, this.onRate});

  final String? titleId;
  final VoidCallback? onRate;

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    if (account.phase != AccountPhase.ready) return const SizedBox.shrink();
    return _Recommendations(
      key: ValueKey((account.userId, titleId)),
      titleId: titleId,
      onRate: onRate,
    );
  }
}

class _Recommendations extends StatefulWidget {
  const _Recommendations({super.key, this.titleId, this.onRate});

  final String? titleId;
  final VoidCallback? onRate;

  @override
  State<_Recommendations> createState() => _RecommendationsState();
}

class _RecommendationsState extends State<_Recommendations> {
  late final _rows = context.read<SocialRepository>().many(
    'followed_recommendations',
    {'target': ?widget.titleId},
  );

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _rows,
    builder: (context, snapshot) {
      final rows = snapshot.data;
      final rate = widget.onRate;
      if (rows == null || rows.isEmpty && rate == null) {
        return const SizedBox.shrink();
      }
      final own = rows.any((row) => row['own'] == true);
      final items = [
        if (rate != null && !own) _RateBubble(onTap: rate),
        for (final row in rows)
          _ActivityAvatar(row, onTap: row['own'] == true ? rate : null),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          SectionHeader(
            rate == null ? 'Following activity' : 'Ratings',
            padding: EdgeInsets.zero,
          ),
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, index) => items[index],
            ),
          ),
        ],
      );
    },
  );
}

class _RateBubble extends StatelessWidget {
  const _RateBubble({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Rate',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: coralColor),
            ),
            child: const Icon(
              PhosphorIconsRegular.plus,
              color: coralColor,
              size: 22,
            ),
          ),
          Positioned(
            top: 54,
            child: Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: coralColor,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: canvasColor, width: 2),
              ),
              child: const Text(
                'Rate',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: onCoralColor,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ActivityAvatar extends StatelessWidget {
  const _ActivityAvatar(this.row, {this.onTap});

  final SocialRow row;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final handle = row['handle'] as String;
    final score = row['score'] as num?;
    final review = row['review'] as SocialRow?;
    final who = row['own'] == true ? 'You' : '@$handle';
    final what = [
      if (score != null) 'rated ${scoreText(score)} of 10',
      if (review != null) 'wrote a review',
      if (score == null && review == null)
        row['kind'] == 'first_show' ? 'started watching' : 'watched',
    ].join(' and ');
    return Semantics(
      button: true,
      label: '$who $what',
      excludeSemantics: true,
      child: GestureDetector(
        onTap:
            onTap ??
            () => context.push(
              review != null
                  ? '/reviews/${review['id']}'
                  : '/people/${row['actor_id']}',
            ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            Avatar(handle, size: 64, userId: row['actor_id'] as String?),
            Positioned(
              top: 54,
              child: Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 7),
                decoration: BoxDecoration(
                  color: pressedColor,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: canvasColor, width: 2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (score != null) ...[
                      const Icon(
                        PhosphorIconsFill.star,
                        size: 11,
                        color: coralColor,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        scoreText(score),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: inkColor,
                        ),
                      ),
                    ],
                    if (review != null) ...[
                      if (score != null) const SizedBox(width: 4),
                      const Icon(Icons.notes, size: 13, color: inkColor),
                    ],
                    if (score == null && review == null)
                      const Icon(
                        PhosphorIconsRegular.check,
                        size: 12,
                        color: inkColor,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> reportSocial(BuildContext context, String id, String kind) async {
  final repo = context.read<SocialRepository>();
  final reason = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Why are you reporting this?'),
      children: [
        for (final label in [
          'Harassment or abuse',
          'Spam or misleading',
          'Unmarked spoiler',
          'Other',
        ])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, label),
            child: Text(label),
          ),
      ],
    ),
  );
  if (reason == null || !context.mounted) return;
  try {
    await repo.change('submit_report', {
      'target': id,
      'kind_value': kind,
      'reason_value': reason,
    });
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Report sent')));
    }
  } on Exception {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not report. Try again.')),
      );
    }
  }
}

class OpinionActions extends StatefulWidget {
  const OpinionActions({
    super.key,
    required this.title,
    required this.label,
    this.season,
    this.showReviews = true,
    this.tiles = true,
  });

  final String title;
  final String label;
  final String? season;
  final bool showReviews;
  final bool tiles;

  @override
  State<OpinionActions> createState() => _OpinionActionsState();
}

class _OpinionActionsState extends State<OpinionActions> {
  late Future<SocialRow?> _opinion = _load();
  int _reviewsVersion = 0;
  bool _saving = false;

  Future<SocialRow?> _load() =>
      context.read<SocialRepository>().opinions(widget.title, widget.season);

  void _refresh() => setState(() {
    _opinion = _load();
    _reviewsVersion++;
  });

  Future<void> _edit(
    SocialRow? value, {
    required bool review,
    SocialRow? myReview,
  }) async {
    final repo = context.read<SocialRepository>();
    final store = context.read<OfflineStore>();
    final owner = context.read<AccountCubit>().state.userId;
    if (owner == null) return;
    final key = '${widget.title}:${widget.season}';
    final draft = review
        ? await store.read(owner, 'drafts', key).catchError((Object _) => null)
              as SocialRow?
        : null;
    if (!mounted) return;
    final result = await showModalBottomSheet<SocialRow>(
      useRootNavigator: true,
      isScrollControlled: true,
      context: context,
      builder: (context) => _OpinionEditor(
        label: widget.label,
        review: review,
        current: draft ?? value,
        canSaveDraft: review && store.available,
        hasReview: review ? null : myReview?['body'] != null,
      ),
    );
    if (!mounted || result == null) return;
    final thenReview = result['then_review'] == true;
    if (thenReview &&
        result['score'] == value?['score'] &&
        result['audience'] == (value?['audience'] ?? 'followers')) {
      return _edit(myReview, review: true);
    }
    setState(() => _saving = true);
    try {
      var revision =
          (draft?['base_revision'] ?? value?['revision']) as int? ?? 0;
      if (review) {
        final latest = value?['revision'] as int? ?? 0;
        if (draft != null && result['draft'] != true && latest != revision) {
          final replace = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: const Text('Replace the current review?'),
              content: const Text(
                'The saved review changed since you started this draft.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Keep draft'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Replace review'),
                ),
              ],
            ),
          );
          if (replace == true) {
            revision = latest;
          } else {
            result['draft'] = true;
          }
        }
        await store
            .write(owner, 'drafts', key, {...result, 'base_revision': revision})
            .catchError((Object error) {
              if (result['draft'] == true) throw error;
            });
        if (result['draft'] == true) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Draft saved on this device')),
            );
          }
          return;
        }
        await repo.saveReview(
          widget.title,
          widget.season,
          result['body'] as String,
          result['spoiler'] as bool,
          result['audience'] as String,
          revision,
        );
        await store.remove(owner, 'drafts', key).catchError((Object _) {});
      } else {
        await repo.rate(
          widget.title,
          widget.season,
          result['score'] as num?,
          result['audience'] as String,
          revision,
          result['share'] as bool,
        );
      }
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not save online. Review the latest value before trying again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        _saving = false;
        _refresh();
      }
    }
    if (thenReview && mounted) await _edit(myReview, review: true);
  }

  @override
  Widget build(BuildContext context) {
    final ready =
        context.watch<AccountCubit>().state.phase == AccountPhase.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.tiles) const SizedBox(height: 8),
        FutureBuilder(
          future: _opinion,
          builder: (context, result) {
            if (result.hasError) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InlineNotice(
                    'Could not load ratings.',
                    icon: PhosphorIconsRegular.warningCircle,
                    action: 'Retry',
                    onAction: _refresh,
                  ),
                  if (ready)
                    TextButton(
                      onPressed: () => _edit(null, review: true),
                      child: const Text('Open review draft'),
                    ),
                ],
              );
            }
            final loading = result.connectionState != ConnectionState.done;
            final data = result.data;
            final rating = data?['my_rating'] as SocialRow?;
            final review = data?['my_review'] as SocialRow?;
            final score = rating?['score'] as num?;
            final reviewed = review?['body'] != null;
            if (!widget.tiles) {
              return FollowedRecommendations(
                key: ValueKey(_reviewsVersion),
                titleId: widget.title,
                onRate: _saving || loading
                    ? null
                    : () => _edit(rating, review: false, myReview: review),
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _StatTile(
                      label: 'Rate ${widget.label}',
                      value: score == null ? null : scoreText(score),
                      reviewed: reviewed,
                      onTap: _saving || loading
                          ? null
                          : () => ready
                                ? _edit(rating, review: false, myReview: review)
                                : context.push('/account'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        if (widget.showReviews)
          TitleReviews(
            key: ValueKey(_reviewsVersion),
            title: widget.title,
            season: widget.season,
          ),
      ],
    );
  }
}

class TitleReviews extends StatefulWidget {
  const TitleReviews({super.key, required this.title, this.season});

  final String title;
  final String? season;

  @override
  State<TitleReviews> createState() => _TitleReviewsState();
}

class _TitleReviewsState extends State<TitleReviews> {
  late Future<List<SocialRow>> _reviews = _load();

  Future<List<SocialRow>> _load() => context.read<SocialRepository>().reviews(
    title: widget.title,
    season: widget.season,
  );

  void _refresh() => setState(() => _reviews = _load());

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _reviews,
    builder: (context, result) {
      if (result.hasError) {
        return InlineNotice(
          'Could not load reviews.',
          icon: PhosphorIconsRegular.warningCircle,
          action: 'Retry',
          onAction: _refresh,
        );
      }
      final reviews = result.data ?? [];
      if (reviews.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          SectionHeader(
            'Reviews',
            padding: EdgeInsets.zero,
            onMore: reviews.length > 3
                ? () => context.push(
                    Uri(
                      path: '/review-list',
                      queryParameters: {
                        'title': widget.title,
                        'season': ?widget.season,
                      },
                    ).toString(),
                  )
                : null,
          ),
          for (final row in reviews.take(3)) ReviewTile(row),
        ],
      );
    },
  );
}

class ExternalRatingChip extends StatelessWidget {
  const ExternalRatingChip(this.rating, {super.key});

  final Map<String, dynamic> rating;

  static String _votes(int count) => count >= 1000000
      ? '${(count / 1000000).toStringAsFixed(1)}M'
      : count >= 1000
      ? '${(count / 1000).round()}K'
      : '$count';

  @override
  Widget build(BuildContext context) {
    final imdb = rating['source'] == 'imdb';
    final value = (rating['value'] as num).toStringAsFixed(1);
    final votes = rating['votes'] as int?;
    final imdbId = rating['imdb_id'] as String?;
    final rotten = rating['rotten'] as int?;
    final chip = Semantics(
      button: imdbId != null,
      label:
          '${imdb ? 'IMDb' : 'TMDB'} rating $value of 10${votes == null ? '' : ', ${_votes(votes)} votes'}',
      excludeSemantics: true,
      child: InkWell(
        onTap: imdbId == null
            ? null
            : () => launchUrl(
                Uri.https('www.imdb.com', '/title/$imdbId/'),
                mode: LaunchMode.externalApplication,
              ),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 18,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: imdb ? const Color(0xfff5c518) : null,
                  gradient: imdb
                      ? null
                      : const LinearGradient(
                          colors: [Color(0xff90cea1), Color(0xff01b4e4)],
                        ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  imdb ? 'IMDb' : 'TMDB',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    letterSpacing: imdb ? -.3 : .4,
                    color: imdb ? Colors.black : const Color(0xff0d253f),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: inkColor,
                ),
              ),
              if (votes != null) ...[
                const SizedBox(width: 4),
                Text(
                  '· ${_votes(votes)}',
                  style: const TextStyle(fontSize: 12, color: mutedColor),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (rotten == null) return chip;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip,
        const SizedBox(width: 16),
        Semantics(
          label: 'Rotten Tomatoes $rotten percent',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvgPicture.asset('assets/brand/tomato.svg', height: 18),
              const SizedBox(width: 6),
              Text(
                '$rotten%',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: inkColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    this.value,
    this.reviewed = false,
    this.onTap,
  });

  final String label;
  final String? value;
  final bool reviewed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final rated = value != null;
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: onTap != null,
        label: [
          label,
          if (rated) '$value of 10',
          if (reviewed) 'Reviewed',
        ].join(', '),
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  rated ? PhosphorIconsFill.star : PhosphorIconsRegular.star,
                  size: 16,
                  color: coralColor,
                ),
                const SizedBox(width: 6),
                Text(
                  [
                    rated ? '$value/10' : label,
                    if (reviewed) 'Reviewed',
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: rated ? FontWeight.w600 : FontWeight.w500,
                    color: rated ? inkColor : coralColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OpinionEditor extends StatefulWidget {
  const _OpinionEditor({
    required this.label,
    required this.review,
    this.current,
    required this.canSaveDraft,
    this.hasReview,
  });

  final String label;
  final bool review;
  final SocialRow? current;
  final bool canSaveDraft;
  final bool? hasReview;

  @override
  State<_OpinionEditor> createState() => _OpinionEditorState();
}

class _OpinionEditorState extends State<_OpinionEditor> {
  late final _text = TextEditingController(
    text: widget.current?['body'] as String?,
  );
  late String _audience = widget.current?['audience'] as String? ?? 'followers';
  late num? _score = widget.current?['score'] as num?;
  late bool _spoiler = widget.current?['spoiler'] == true;
  late bool _share = widget.current == null;

  void _finish({bool draft = false, bool thenReview = false}) =>
      Navigator.pop(context, {
        'body': _text.text.trim(),
        'score': _score,
        'spoiler': _spoiler,
        'audience': _audience,
        'share': _share,
        'draft': draft,
        'then_review': thenReview,
      });

  VoidCallback _step(num delta) =>
      () => setState(() {
        final next = (_score ?? 0) + delta;
        _score = next < .5 ? null : next.clamp(.5, 10);
      });

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.review ? 'Review' : 'Rate'} ${widget.label}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          if (widget.review) ...[
            TextField(
              controller: _text,
              maxLength: 5000,
              minLines: 4,
              maxLines: 10,
              autofocus: _text.text.isEmpty,
              decoration: const InputDecoration(
                hintText: 'What did you think?',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Contains spoilers'),
              value: _spoiler,
              onChanged: (value) => setState(() => _spoiler = value),
            ),
          ] else ...[
            Semantics(
              slider: true,
              label: 'Rating',
              value: _score == null
                  ? 'No rating'
                  : '${scoreText(_score!)} of 10',
              increasedValue:
                  '${scoreText(((_score ?? 0) + .5).clamp(.5, 10))} of 10',
              decreasedValue: _score == null || _score! <= .5
                  ? 'No rating'
                  : '${scoreText(_score! - .5)} of 10',
              onIncrease: _score == 10 ? null : _step(.5),
              onDecrease: _score == null ? null : _step(-.5),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var star = 1; star <= 5; star++)
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: Stack(
                          children: [
                            Center(
                              child: SizedBox.square(
                                dimension: 40,
                                child: Stack(
                                  children: [
                                    const Icon(
                                      PhosphorIconsRegular.star,
                                      color: coralColor,
                                      size: 40,
                                    ),
                                    ClipRect(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        widthFactor:
                                            (((_score ?? 0) - (star - 1) * 2) /
                                                    2)
                                                .clamp(0, 1)
                                                .toDouble(),
                                        child: const Icon(
                                          PhosphorIconsFill.star,
                                          color: coralColor,
                                          size: 40,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                for (final value in [star * 2 - 1, star * 2])
                                  Expanded(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () =>
                                          setState(() => _score = value),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Half a point less',
                  onPressed: _score == null ? null : _step(-.5),
                  icon: const Icon(PhosphorIconsRegular.minus),
                ),
                SizedBox(
                  width: 112,
                  child: Text(
                    _score == null ? 'No rating' : '${scoreText(_score!)} / 10',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Half a point more',
                  onPressed: _score == 10 ? null : _step(.5),
                  icon: const Icon(PhosphorIconsRegular.plus),
                ),
              ],
            ),
            if (_score != null)
              Center(
                child: TextButton(
                  onPressed: () => setState(() => _score = null),
                  style: TextButton.styleFrom(foregroundColor: mutedColor),
                  child: const Text('Clear rating'),
                ),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            'Who can see this',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              for (final option in audienceLabels.entries)
                ButtonSegment(value: option.key, label: Text(option.value)),
            ],
            selected: {_audience},
            onSelectionChanged: (value) => setState(() {
              _audience = value.first;
              if (_audience == 'only_me') _share = false;
            }),
          ),
          if (!widget.review && _audience != 'only_me')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _share,
              title: const Text('Share to Following'),
              onChanged: (value) => setState(() => _share = value),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _finish,
            child: Text(
              widget.review && _audience != 'only_me'
                  ? 'Publish review'
                  : 'Save',
            ),
          ),
          if (widget.canSaveDraft)
            TextButton(
              onPressed: () => _finish(draft: true),
              child: const Text('Save draft on device'),
            ),
          if (widget.hasReview case final hasReview?) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _finish(thenReview: true),
              icon: Icon(
                hasReview
                    ? PhosphorIconsFill.notePencil
                    : PhosphorIconsRegular.pencilSimple,
              ),
              label: Text(hasReview ? 'Edit review' : 'Write a review'),
            ),
          ],
        ],
      ),
    ),
  );
}

class ReviewTile extends StatelessWidget {
  const ReviewTile(this.row, {super.key, this.showTitle = false});

  final SocialRow row;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final protected = row['protected'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: InkWell(
          onTap: () => context.push('/reviews/${row['id']}'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (!showTitle) ...[
                      Avatar(
                        row['handle'] as String? ?? '',
                        size: 28,
                        userId: row['author_id'] as String?,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        showTitle
                            ? '${row['title']}${row['season'] == null ? '' : ' · ${row['season']}'}'
                            : '@${row['handle']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (row['score'] case final num score) StarScore(score),
                  ],
                ),
                const SizedBox(height: 8),
                if (protected)
                  const Row(
                    children: [
                      Icon(
                        PhosphorIconsRegular.eyeSlash,
                        size: 18,
                        color: mutedColor,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Spoilers hidden · Tap to reveal',
                        style: TextStyle(color: mutedColor),
                      ),
                    ],
                  )
                else
                  Text(
                    row['body'] as String? ?? '',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, height: 1.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ReviewListPage extends StatefulWidget {
  const ReviewListPage({super.key, this.titleId, this.seasonId, this.author});

  final String? titleId;
  final String? seasonId;
  final String? author;

  @override
  State<ReviewListPage> createState() => _ReviewListPageState();
}

class _ReviewListPageState extends State<ReviewListPage> {
  final _items = <SocialRow>[];
  bool _loading = true, _error = false, _more = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final rows = await context.read<SocialRepository>().reviews(
        title: widget.titleId,
        season: widget.seasonId,
        author: widget.author,
        after: append ? _items.lastOrNull : null,
      );
      if (mounted) {
        setState(() {
          if (!append) _items.clear();
          _items.addAll(rows);
          _more = rows.length == 20;
        });
      }
    } on Exception {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reviews')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final row in _items)
          ReviewTile(row, showTitle: widget.author != null),
        if (_loading) const LinearProgressIndicator(),
        if (_error) TextButton(onPressed: _load, child: const Text('Retry')),
        if (!_loading && !_error && _items.isEmpty)
          const Text('No reviews to show.'),
        if (!_loading && _more && _items.isNotEmpty)
          TextButton(
            onPressed: () => _load(append: true),
            child: const Text('Load more'),
          ),
      ],
    ),
  );
}

class ReviewDetailPage extends StatefulWidget {
  const ReviewDetailPage({super.key, required this.id});

  final String id;

  @override
  State<ReviewDetailPage> createState() => _ReviewDetailPageState();
}

class _ReviewDetailPageState extends State<ReviewDetailPage> {
  SocialRow? _data;
  final _comments = <SocialRow>[];
  bool _reveal = false, _working = false, _failed = false, _more = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({String? revealedComment, bool more = false}) async {
    if (_working) return;
    setState(() {
      _working = true;
      _failed = false;
    });
    try {
      final last = more ? _comments.lastOrNull : null;
      final result = await context.read<SocialRepository>().one(
        'review_detail',
        {
          'review': widget.id,
          'reveal': _reveal,
          'reveal_comment': ?revealedComment,
          'after_time': ?last?['created_at'],
          'after_id': ?last?['id'],
        },
      );
      if (!mounted) return;
      final rows = (result?['comments'] as List? ?? []).cast<SocialRow>();
      setState(() {
        _data = result;
        if (!more) _comments.clear();
        _comments.addAll(rows);
        _more = rows.length == 30;
      });
    } on Exception {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _write(String rpc, SocialRow params) async {
    try {
      await context.read<SocialRepository>().change(rpc, params);
      if (mounted) await _load();
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save. Try again.')),
        );
      }
    }
  }

  Future<void> _comment([SocialRow? existing]) async {
    final text = TextEditingController(text: existing?['body'] as String?);
    var spoiler = existing?['spoiler'] == true;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(existing == null ? 'Add a comment' : 'Edit comment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: text,
                maxLength: 2000,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Comment'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Contains spoilers'),
                value: spoiler,
                onChanged: (value) => update(() => spoiler = value ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, text.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    text.dispose();
    if (!mounted || result == null || result.isEmpty) return;
    await _write('set_comment', {
      'review': widget.id,
      'comment': existing?['id'] ?? const Uuid().v4(),
      'action': existing == null ? 'add' : 'edit',
      'content': result,
      'spoiler': spoiler,
      'observed_revision': ?existing?['revision'],
      'reveal': _reveal,
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    final ready = account.phase == AccountPhase.ready;
    final data = _data;
    final open = data != null && (_reveal || data['protected'] != true);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review'),
        actions: [
          if (data != null && ready)
            PopupMenuButton<String>(
              tooltip: 'More actions',
              icon: const Icon(PhosphorIconsRegular.dotsThree),
              onSelected: (_) => reportSocial(context, widget.id, 'review'),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'report', child: Text('Report')),
              ],
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (_failed)
              InlineNotice(
                'Could not open this review.',
                icon: PhosphorIconsRegular.warningCircle,
                action: 'Retry',
                onAction: _load,
              ),
            if (_working)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(),
              ),
            if (!_working && !_failed && data == null)
              const EmptyState(
                icon: PhosphorIconsRegular.lock,
                title: 'Review unavailable',
                message: 'It may have been removed or made private.',
              ),
            if (data != null) ...[
              Text(
                '${data['title']}${data['season'] == null ? '' : ' · ${data['season']}'}',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () => context.push('/people/${data['author_id']}'),
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  children: [
                    Avatar(
                      data['handle'] as String,
                      size: 40,
                      userId: data['author_id'] as String?,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '@${data['handle']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (data['score'] case final num score)
                      StarScore(score, large: true),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (!open)
                Card(
                  child: ListTile(
                    leading: const Icon(PhosphorIconsRegular.eyeSlash),
                    title: const Text('This review has spoilers'),
                    trailing: const Text(
                      'Reveal',
                      style: TextStyle(
                        color: coralColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onTap: () {
                      _reveal = true;
                      _load();
                    },
                  ),
                )
              else if (data['body'] case final String body)
                SelectableText(
                  body,
                  style: const TextStyle(fontSize: 16, height: 1.6),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (ready)
                    TextButton.icon(
                      onPressed: _working
                          ? null
                          : () => _write('set_review_like', {
                              'review': widget.id,
                              'liked': data['liked'] != true,
                            }),
                      icon: Icon(
                        data['liked'] == true
                            ? PhosphorIconsFill.heart
                            : PhosphorIconsRegular.heart,
                        color: data['liked'] == true ? coralColor : null,
                      ),
                      label: Text('${data['likes']}'),
                      style: TextButton.styleFrom(foregroundColor: inkColor),
                    ),
                  if (ready && open)
                    TextButton.icon(
                      onPressed: _comment,
                      icon: const Icon(PhosphorIconsRegular.chatCircle),
                      label: const Text('Comment'),
                    ),
                  const Spacer(),
                  if (data['public'] == true)
                    IconButton(
                      tooltip: 'Copy link',
                      icon: const Icon(PhosphorIconsRegular.export),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text:
                                '$backendUrl/functions/v1/share/review/${widget.id}',
                          ),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Link copied')),
                          );
                        }
                      },
                    ),
                ],
              ),
              const Divider(),
              if (_comments.isNotEmpty)
                SectionHeader(
                  'Comments · ${_comments.length}${_more ? '+' : ''}',
                  padding: const EdgeInsets.only(top: 8),
                ),
              for (final comment in _comments)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Avatar(
                        comment['handle'] as String,
                        size: 32,
                        userId: comment['author_id'] as String?,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '@${comment['handle']}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (comment['body'] == null)
                              TextButton(
                                onPressed: () => _load(
                                  revealedComment: comment['id'] as String,
                                ),
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  foregroundColor: coralColor,
                                ),
                                child: const Text('Reveal spoiler'),
                              )
                            else
                              Text(
                                comment['body'] as String,
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.5,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (ready)
                        PopupMenuButton<String>(
                          tooltip: 'Comment actions',
                          icon: const Icon(
                            PhosphorIconsRegular.dotsThree,
                            size: 20,
                            color: mutedColor,
                          ),
                          itemBuilder: (context) => [
                            if (comment['author_id'] == account.userId) ...[
                              if (comment['body'] != null)
                                const PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Edit'),
                                ),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('Delete'),
                              ),
                            ] else if (data['author_id'] == account.userId)
                              const PopupMenuItem(
                                value: 'hide',
                                child: Text('Hide'),
                              ),
                            const PopupMenuItem(
                              value: 'report',
                              child: Text('Report'),
                            ),
                          ],
                          onSelected: (action) {
                            if (action == 'edit') {
                              _comment(comment);
                            } else if (action == 'report') {
                              reportSocial(
                                context,
                                comment['id'] as String,
                                'comment',
                              );
                            } else {
                              _write('set_comment', {
                                'review': widget.id,
                                'comment': comment['id'],
                                'action': action,
                                'observed_revision': comment['revision'],
                                'reveal': _reveal,
                              });
                            }
                          },
                        ),
                    ],
                  ),
                ),
              if (_more)
                OutlinedButton(
                  onPressed: _working ? null : () => _load(more: true),
                  child: const Text('Load more comments'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
