import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

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
    return _Recommendations(key: ValueKey((account.userId,titleId)), titleId: titleId);
  }
}

class _Recommendations extends StatefulWidget {
  const _Recommendations({super.key, this.titleId});
  final String? titleId;

  @override
  State<_Recommendations> createState() => _RecommendationsState();
}

class _RecommendationsState extends State<_Recommendations> {
  late final _rows = context.read<SocialRepository>().many('followed_recommendations', {'target':?widget.titleId});

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _rows, builder: (context, snapshot) {
      final rows = snapshot.data;
      if (rows == null || rows.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 20),
        Text(widget.titleId == null ? 'From people you follow' : 'Following activity',
            style: Theme.of(context).textTheme.titleLarge),
        for (final row in rows) ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(row['title'] as String),
          subtitle: Text('@${row['handle']} ${switch (row['kind']) {
              'review' => 'wrote a review', 'rating' => 'rated this ${(row['score'] as int) / 2} of 5 stars',
              'first_show' => 'started watching', _ => 'marked watched',
            }}'),
          onTap: () {
            if (row['review'] case final SocialRow review) {
              context.push('/reviews/${review['id']}');
            } else if (widget.titleId == null) {
              context.push('/titles/${row['media']}/${row['tmdb_id']}');
            } else {
              context.push('/people/${row['actor_id']}');
            }
          },
        ),
      ]);
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
  });
  final String title;
  final String label;
  final String? season;

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
    final draft = review ? await store.read(owner,'drafts',key).catchError((Object _) => null) as SocialRow? : null;
    if (!mounted) return;
    final result = await showModalBottomSheet<SocialRow>(
      isScrollControlled: true,
      context: context,
      builder: (context) =>
          _OpinionEditor(label: widget.label, review: review, current: draft ?? value, canSaveDraft: review && store.available),
    );
    if (!mounted || result == null) return;
    setState(() => _saving = true);
    try {
      var revision = (draft?['base_revision'] ?? value?['revision']) as int? ?? 0;
      if (review) {
        final latest = value?['revision'] as int? ?? 0;
        if (draft != null && result['draft'] != true && latest != revision) {
          final replace = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
            title: const Text('Replace the current review?'),
            content: const Text('The saved review changed since you started this draft.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog,false), child: const Text('Keep draft')),
              TextButton(onPressed: () => Navigator.pop(dialog,true), child: const Text('Replace review')),
            ],
          ));
          if (replace == true) revision = latest;
          else result['draft'] = true;
        }
        await store.write(owner,'drafts',key,{...result,'base_revision':revision}).catchError((Object error) {
          if (result['draft'] == true) throw error;
        });
        if (result['draft'] == true) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Draft saved on this device')));
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
        await store.remove(owner,'drafts',key).catchError((Object _) {});
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
        const SizedBox(height: 20),
        FutureBuilder(
          future: _opinion,
          builder: (context, result) {
            if (result.hasError) {
              return Wrap(children: [
                TextButton(onPressed: _refresh, child: const Text('Could not load opinions. Retry')),
                if (ready) TextButton(onPressed: () => _edit(null,review:true), child: const Text('Open review draft')),
              ]);
            }
            if (result.connectionState != ConnectionState.done) {
              return const LinearProgressIndicator();
            }
            final data = result.data;
            final rating = data?['my_rating'] as SocialRow?;
            final review = data?['my_review'] as SocialRow?;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data?['average'] != null
                      ? 'Community · ${data!['average']} ★ (${data['rating_count']})'
                      : 'Community · Insufficient ratings',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => ready
                                ? _edit(rating, review: false)
                                : context.push('/account'),
                      child: Text(
                        rating?['score'] == null
                            ? 'Rate ${widget.label}'
                            : 'Your ${widget.label} rating · ${(rating!['score'] as int) / 2} ★',
                      ),
                    ),
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => ready
                                ? _edit(review, review: true)
                                : context.push('/account'),
                      child: Text(
                        review?['body'] == null
                            ? 'Review ${widget.label}'
                            : 'Edit ${widget.label} review',
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
        FutureBuilder(
          future: _reviews,
          builder: (context, result) {
            if (result.hasError) {
              return TextButton(
                onPressed: _refresh,
                child: const Text('Could not load reviews. Retry'),
              );
            }
            final reviews = result.data ?? [];
            if (reviews.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reviews', style: Theme.of(context).textTheme.titleMedium),
                for (final row in reviews.take(3)) ReviewTile(row),
                if (reviews.length > 3)
                  TextButton(
                    onPressed: () => context.push(
                      Uri(
                        path: '/review-list',
                        queryParameters: {
                          'title': widget.title,
                          'season': ?widget.season,
                        },
                      ).toString(),
                    ),
                    child: const Text('See all reviews'),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
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
    'body':_text.text.trim(),'score':_score,'spoiler':_spoiler,'audience':_audience,'share':_share,'draft':draft,
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
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
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
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Your review'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Contains spoilers'),
              value: _spoiler,
              onChanged: (value) => setState(() => _spoiler = value ?? false),
            ),
          ] else
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                IconButton(
                  tooltip: 'Decrease by half a star',
                  onPressed: _score == null
                      ? null
                      : () => setState(() {
                          _score = _score! == 1 ? null : _score! - 1;
                        }),
                  icon: const Icon(Icons.remove),
                ),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _score == null ? 'No rating' : '${_score! / 2} of 5 ★',
                  ),
                ),
                IconButton(
                  tooltip: 'Increase by half a star',
                  onPressed: _score == 10
                      ? null
                      : () => setState(() {
                          _score = (_score ?? 0) + 1;
                        }),
                  icon: const Icon(Icons.add),
                ),
                TextButton(
                  onPressed: _score == null
                      ? null
                      : () => setState(() => _score = null),
                  child: const Text('Clear'),
                ),
              ],
            ),
          DropdownButtonFormField<String>(
            initialValue: _audience,
            decoration: const InputDecoration(labelText: 'Audience'),
            items: [
              for (final option in audienceLabels.entries)
                DropdownMenuItem(value: option.key, child: Text(option.value)),
            ],
            onChanged: (value) => setState(() {
              _audience = value!;
              if (_audience == 'only_me') _share = false;
            }),
          ),
          if (!widget.review && _audience != 'only_me')
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _share,
              title: const Text('Share to Following'),
              onChanged: (value) => setState(() => _share = value ?? false),
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
            TextButton(onPressed: () => _finish(draft:true), child: const Text('Save draft on device')),
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
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(
      showTitle
          ? '${row['title']}${row['season'] == null ? '' : ' · ${row['season']}'}'
          : '@${row['handle']}',
    ),
    subtitle: Text(
      row['protected'] == true
          ? 'Spoilers hidden · Reveal'
          : (row['body'] as String? ?? ''),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: row['score'] == null
        ? null
        : Text('${(row['score'] as int) / 2} ★'),
    onTap: () => context.push('/reviews/${row['id']}'),
  );
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
    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_failed)
              TextButton(
                onPressed: _load,
                child: const Text('Could not open this review. Retry'),
              ),
            if (_working) const LinearProgressIndicator(),
            if (!_working && !_failed && data == null)
              const Text('This review is unavailable.'),
            if (data != null) ...[
              Text(
                '${data['title']}${data['season'] == null ? '' : ' · ${data['season']}'}',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              TextButton(
                onPressed: () => context.push('/people/${data['author_id']}'),
                child: Text('@${data['handle']}'),
              ),
              if (data['score'] != null)
                Text('${(data['score'] as int) / 2} of 5 ★'),
              const SizedBox(height: 12),
              if (data['protected'] == true && !_reveal)
                OutlinedButton(
                  onPressed: () {
                    _reveal = true;
                    _load();
                  },
                  child: const Text('Reveal spoiler'),
                )
              else if (data['body'] case final String body)
                Text(body),
              if (ready)
                Wrap(
                  children: [
                    TextButton.icon(
                      onPressed: _working
                          ? null
                          : () => _write('set_review_like', {
                              'review': widget.id,
                              'liked': data['liked'] != true,
                            }),
                      icon: Icon(
                        data['liked'] == true
                            ? Icons.favorite
                            : Icons.favorite_border,
                      ),
                      label: Text(
                        '${data['liked'] == true ? 'Liked' : 'Like'} · ${data['likes']}',
                      ),
                    ),
                    if (_reveal || data['protected'] != true)
                      TextButton(
                        onPressed: _comment,
                        child: const Text('Comment'),
                      ),
                    TextButton(
                      onPressed: () =>
                          reportSocial(context, widget.id, 'review'),
                      child: const Text('Report'),
                    ),
                    if (data['public'] == true)
                      TextButton(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(
                              text:
                                  '$backendUrl/functions/v1/share/review/${widget.id}',
                            ),
                          );
                        },
                        child: const Text('Copy link'),
                      ),
                  ],
                ),
              if (_comments.isNotEmpty)
                Text('Comments', style: Theme.of(context).textTheme.titleLarge),
              for (final comment in _comments)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('@${comment['handle']}'),
                  subtitle: comment['body'] == null
                      ? TextButton(
                          onPressed: () =>
                              _load(revealedComment: comment['id'] as String),
                          child: const Text('Reveal spoiler'),
                        )
                      : Text(comment['body'] as String),
                  trailing: !ready
                      ? null
                      : PopupMenuButton<String>(
                          tooltip: 'Comment actions',
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
                ),
              if (_more)
                TextButton(
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
