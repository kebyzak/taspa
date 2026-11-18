import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
  const FollowedRecommendations({super.key, this.titleId});
  final String? titleId;

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    if (account.phase != AccountPhase.ready) return const SizedBox.shrink();
    return _Recommendations(
      key: ValueKey((account.userId, titleId)),
      titleId: titleId,
    );
  }
}

class _Recommendations extends StatefulWidget {
  const _Recommendations({super.key, this.titleId});
  final String? titleId;

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
      if (rows == null || rows.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          SectionHeader(
            widget.titleId == null
                ? 'From people you follow'
                : 'Following activity',
            padding: EdgeInsets.zero,
          ),
          Card(
            child: Column(
              children: [
                for (final (index, row) in rows.indexed) ...[
                  if (index > 0) const Divider(indent: 64),
                  ListTile(
                    leading: Avatar(row['handle'] as String, size: 36),
                    title: Text(
                      row['title'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '@${row['handle']} ${switch (row['kind']) {
                        'review' => 'wrote a review',
                        'rating' => 'rated it ${row['score']}/10',
                        'first_show' => 'started watching',
                        _ => 'watched it',
                      }}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(PhosphorIconsRegular.caretRight),
                    onTap: () {
                      if (row['review'] case final SocialRow review) {
                        context.push('/reviews/${review['id']}');
                      } else if (widget.titleId == null) {
                        context.push(
                          '/titles/${row['media']}/${row['tmdb_id']}',
                        );
                      } else {
                        context.push('/people/${row['actor_id']}');
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    },
  );
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
    this.external,
  });
  final String title;
  final String label;
  final String? season;

  /// IMDb or TMDB score from the catalog (`details.rating`); shown instead of the community average.
  final Map<String, dynamic>? external;

  @override
  State<OpinionActions> createState() => _OpinionActionsState();
}

class _OpinionActionsState extends State<OpinionActions> {
  late Future<SocialRow?> _opinion = _load();
  late Future<List<SocialRow>> _reviews = _loadReviews();
  bool _saving = false;

  Future<SocialRow?> _load() =>
      context.read<SocialRepository>().opinions(widget.title, widget.season);
  Future<List<SocialRow>> _loadReviews() => context
      .read<SocialRepository>()
      .reviews(title: widget.title, season: widget.season);
  void _refresh() => setState(() {
    _opinion = _load();
    _reviews = _loadReviews();
  });

  Future<void> _edit(SocialRow? value, {required bool review}) async {
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
      ),
    );
    if (!mounted || result == null) return;
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
          if (replace == true)
            revision = latest;
          else
            result['draft'] = true;
        }
        await store
            .write(owner, 'drafts', key, {...result, 'base_revision': revision})
            .catchError((Object error) {
              if (result['draft'] == true) throw error;
            });
        if (result['draft'] == true) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Draft saved on this device')),
            );
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
          result['score'] as int?,
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
  }

  @override
  Widget build(BuildContext context) {
    final ready =
        context.watch<AccountCubit>().state.phase == AccountPhase.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
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
            final score = rating?['score'] as int?;
            void open({required bool asReview}) => ready
                ? _edit(asReview ? review : rating, review: asReview)
                : context.push('/account');
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.external case final rating?) ...[
                  Expanded(child: ExternalRatingTile(rating)),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: _StatTile(
                    label: score == null
                        ? 'Rate ${widget.label}'
                        : 'Your ${widget.label} rating',
                    value: score == null ? null : '$score',
                    caption: score == null ? 'Tap to rate' : 'Tap to edit',
                    star: true,
                    onTap: _saving || loading
                        ? null
                        : () => open(asReview: false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatTile(
                    label: review?['body'] == null
                        ? 'Review ${widget.label}'
                        : 'Edit ${widget.label} review',
                    icon: review?['body'] == null
                        ? PhosphorIconsRegular.pencilSimple
                        : PhosphorIconsFill.notePencil,
                    caption: review?['body'] == null ? 'Write' : 'Saved',
                    onTap: _saving || loading
                        ? null
                        : () => open(asReview: true),
                  ),
                ),
              ],
            );
          },
        ),
        FutureBuilder(
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
                const SizedBox(height: 16),
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
        ),
      ],
    );
  }
}

/// IMDb (or TMDB fallback) score tile with the source's badge; tapping opens the IMDb page when known.
class ExternalRatingTile extends StatelessWidget {
  const ExternalRatingTile(this.rating, {super.key});
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
    return Semantics(
      button: imdbId != null,
      label:
          '${imdb ? 'IMDb' : 'TMDB'} rating $value of 10${votes == null ? '' : ', ${_votes(votes)} votes'}',
      excludeSemantics: true,
      child: Material(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: imdbId == null
              ? null
              : () => launchUrl(
                  Uri.https('www.imdb.com', '/title/$imdbId/'),
                  mode: LaunchMode.externalApplication,
                ),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Source badge in each service's own colours, like the logos people recognise.
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
                const SizedBox(height: 4),
                SizedBox(
                  height: 28,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        value,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Text(
                        '/10',
                        style: TextStyle(fontSize: 12, color: mutedColor),
                      ),
                    ],
                  ),
                ),
                Text(
                  votes == null
                      ? (imdb ? 'IMDb' : 'TMDB')
                      : '${_votes(votes)} votes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: mutedColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact rating/review tile: label on top, big value or icon, small caption.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    this.value,
    this.caption,
    this.icon,
    this.star = false,
    this.onTap,
  });
  final String label;
  final String? value;
  final String? caption;
  final IconData? icon;
  final bool star;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: [label, if (value != null) '$value of 10', ?caption].join(', '),
    excludeSemantics: true,
    child: Material(
      color: surfaceColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: mutedColor,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 28,
                child: Row(
                  children: [
                    if (star)
                      Icon(
                        value == null
                            ? PhosphorIconsRegular.star
                            : PhosphorIconsFill.star,
                        color: coralColor,
                        size: 22,
                      ),
                    if (icon != null) Icon(icon, color: coralColor, size: 22),
                    if (value != null) ...[
                      const SizedBox(width: 4),
                      Text(
                        value!,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (caption != null)
                Text(
                  caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: mutedColor),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _OpinionEditor extends StatefulWidget {
  const _OpinionEditor({
    required this.label,
    required this.review,
    this.current,
    required this.canSaveDraft,
  });
  final String label;
  final bool review;
  final SocialRow? current;
  final bool canSaveDraft;

  @override
  State<_OpinionEditor> createState() => _OpinionEditorState();
}

class _OpinionEditorState extends State<_OpinionEditor> {
  late final _text = TextEditingController(
    text: widget.current?['body'] as String?,
  );
  late String _audience = widget.current?['audience'] as String? ?? 'only_me';
  late int? _score = widget.current?['score'] as int?;
  late bool _spoiler = widget.current?['spoiler'] == true;
  bool _share = false;

  void _finish({bool draft = false}) => Navigator.pop(context, {
    'body': _text.text.trim(),
    'score': _score,
    'spoiler': _spoiler,
    'audience': _audience,
    'share': _share,
    'draft': draft,
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
              value: _score == null ? 'No rating' : '$_score of 10',
              increasedValue: '${((_score ?? 0) + 1).clamp(1, 10)} of 10',
              decreasedValue: _score == null || _score == 1
                  ? 'No rating'
                  : '${_score! - 1} of 10',
              onIncrease: _score == 10
                  ? null
                  : () => setState(() => _score = (_score ?? 0) + 1),
              onDecrease: _score == null
                  ? null
                  : () => setState(
                      () => _score = _score! == 1 ? null : _score! - 1,
                    ),
              // Ten stars share the row width so they fit any phone without wrapping.
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    for (var star = 1; star <= 10; star++)
                      Expanded(
                        child: InkResponse(
                          onTap: () => setState(() => _score = star),
                          radius: 20,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Icon(
                              (_score ?? 0) >= star
                                  ? PhosphorIconsFill.star
                                  : PhosphorIconsRegular.star,
                              color: coralColor,
                              size: 28,
                            ),
                          ),
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
                  tooltip: 'Decrease by one',
                  onPressed: _score == null
                      ? null
                      : () => setState(
                          () => _score = _score! == 1 ? null : _score! - 1,
                        ),
                  icon: const Icon(PhosphorIconsRegular.minus),
                ),
                SizedBox(
                  width: 96,
                  child: Text(
                    _score == null ? 'No rating' : '$_score / 10',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Increase by one',
                  onPressed: _score == 10
                      ? null
                      : () => setState(() => _score = (_score ?? 0) + 1),
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
                      Avatar(row['handle'] as String? ?? '', size: 28),
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
                    if (row['score'] case final int score) StarScore(score),
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
                    Avatar(data['handle'] as String, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '@${data['handle']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (data['score'] case final int score)
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
                      Avatar(comment['handle'] as String, size: 32),
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
