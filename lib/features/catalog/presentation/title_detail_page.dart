import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../../core/backend_config.dart';
import '../../auth/auth_cubit.dart';
import '../../library/data/library_repository.dart';
import '../../library/presentation/tracking_cubit.dart';
import '../../social/presentation/reviews.dart';
import '../data/catalog_repository.dart';
import 'artwork.dart';
import 'discover_page.dart';
import 'show_seasons.dart';

class TitleDetailPage extends StatefulWidget {
  const TitleDetailPage({super.key, this.kind, this.tmdbId, this.titleId})
    : assert((kind != null && tmdbId != null) || titleId != null);
  final MediaKind? kind;
  final int? tmdbId;
  final String? titleId;

  @override
  State<TitleDetailPage> createState() => _TitleDetailPageState();
}

class _TitleDetailPageState extends State<TitleDetailPage> {
  late Future<CatalogTitle> _title = _load();

  Future<CatalogTitle> _load() {
    final catalog = context.read<CatalogRepository>();
    final id = widget.titleId;
    return id == null ? catalog.detail(widget.kind!, widget.tmdbId!) : catalog.sharedTitle(id);
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    return FutureBuilder(
      future: _title,
      builder: (context, snapshot) {
        if (snapshot.data case final title?) {
          return _TitleBody(
            key: ValueKey((title.id, account.userId, account.phase)),
            title: title,
            ready: account.phase == AccountPhase.ready,
          );
        }
        return Scaffold(
          appBar: AppBar(),
          body: Center(
            child: snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Could not load this title.'),
                      TextButton(
                        onPressed: () => setState(() => _title = _load()),
                        child: const Text('Retry'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        );
      },
    );
  }
}

class _TitleBody extends StatefulWidget {
  const _TitleBody({super.key, required this.title, required this.ready});
  final CatalogTitle title;
  final bool ready;

  @override
  State<_TitleBody> createState() => _TitleBodyState();
}

class _TitleBodyState extends State<_TitleBody> {
  TrackingCubit? _tracking;
  bool _pending = false;
  String? _error;
  TrackingCommand? _retry;

  @override
  void initState() {
    super.initState();
    final id = widget.title.id;
    if (widget.ready && id != null) {
      final repo = context.read<LibraryRepository>();
      unawaited(repo.rememberTitle(widget.title));
      _tracking = TrackingCubit(repo, id);
      _refresh();
    }
  }

  @override
  void dispose() {
    _tracking?.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      await _tracking?.load();
      if (mounted) setState(() => _error = null);
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Could not load your tracking status.');
      }
    }
  }

  Future<void> _apply(TrackingCommand command, {bool undo = false}) async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _error = null;
      _retry = null;
    });
    try {
      final canUndo = undo ? false : await _tracking!.apply(command);
      if (undo) await _tracking!.undo(command);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            undo
                ? (_tracking?.state?.undoSkipped ?? 0) > 0
                      ? 'Undid available changes. Newer edits were kept.'
                      : 'Change undone'
                : _tracking?.state?.syncStatus == 'pending' ? 'Change saved on this device. Pending sync.' : switch (command.action) {
                    'mark_movie_watched' => 'Marked watched',
                    'log_rewatch' => 'Rewatch logged',
                    'start_show' => 'Started watching',
                    'set_show_intent' => 'Show status updated',
                    'set_episode_watched' =>
                      command.payload['watched'] == true
                          ? 'Episode marked watched'
                          : 'Episode marked unwatched',
                    'edit_episode_watch_date' => 'Watch date updated',
                    'apply_show_batch' => 'Show tracking updated',
                    'set_wanted' =>
                      command.payload['wanted'] == true
                          ? 'Added to Wanted'
                          : 'Removed from Wanted',
                    _ => 'Viewing updated',
                  },
          ),
          action: canUndo
              ? SnackBarAction(
                  label: 'Undo',
                  onPressed: () => _apply(
                    TrackingCommand(command.titleId, 'undo', {
                      'original_operation_id': command.id,
                    }),
                    undo: true,
                  ),
                )
              : null,
        ),
      );
    } on Exception catch (error) {
      if (!mounted) return;
      if (isTrackingConflict(error)) await _refresh();
      if (!mounted) return;
      setState(() {
        _error = trackingMessage(error);
        _retry = isTrackingConflict(error) ? null : command;
      });
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _dateAction(String action, [Viewing? entry]) async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      firstDate: DateTime(1870),
      lastDate: now,
      initialDate: entry?.day == null ? now : DateTime.parse(entry!.day!),
    );
    if (!mounted || selected == null) return;
    await _apply(
      TrackingCommand(widget.title.id!, action, {
        'viewing_id': entry?.id ?? const Uuid().v4(),
        if (entry != null) 'revision': entry.revision,
        'watched_on': selected.toIso8601String().split('T').first,
      }),
    );
  }

  Future<void> _history() async {
    final repo = context.read<LibraryRepository>();
    final selected =
        await showModalBottomSheet<({Viewing entry, String action})>(
          context: context,
          isScrollControlled: true,
          builder: (context) =>
              _ViewingHistory(repository: repo, titleId: widget.title.id!),
        );
    if (selected == null || !mounted) return;
    if (selected.action == 'edit_movie_viewing') {
      await _dateAction(selected.action, selected.entry);
    } else {
      if (selected.action == 'delete_movie_viewing') {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this viewing?'),
            content: const Text('This removes only the selected viewing.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete viewing'),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
      }
      await _apply(
        TrackingCommand(
          widget.title.id!,
          selected.action == 'clear' ? 'edit_movie_viewing' : selected.action,
          {
            'viewing_id': selected.entry.id,
            'revision': selected.entry.revision,
          },
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracker = _tracking;
    return tracker == null
        ? _content(null)
        : BlocBuilder<TrackingCubit, TrackingState?>(
            bloc: tracker,
            builder: (context, state) => _content(state),
          );
  }

  Widget _content(TrackingState? state) {
    final title = widget.title;
    final isMovie = title.kind == MediaKind.movie;
    final release = title.releaseDay;
    final upcoming =
        release != null && release.isAfter(DateUtils.dateOnly(DateTime.now()));
    final theme = Theme.of(context);
    final primary = !widget.ready
        ? OutlinedButton(
            onPressed: () => context.push('/account', extra: title.location),
            child: const Text('Sign in to track'),
          )
        : state == null
        ? null
        : isMovie && !upcoming
        ? FilledButton(
            onPressed: _pending
                ? null
                : state.viewings > 0
                ? () =>
                      showModalBottomSheet<bool>(
                        context: context,
                        builder: (context) => SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Choose viewing date'),
                                ),
                                OutlinedButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text(
                                    'Save rewatch without date',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ).then((dated) {
                        if (!mounted || dated == null) return;
                        if (dated) {
                          _dateAction('log_rewatch');
                        } else {
                          _apply(
                            TrackingCommand(title.id!, 'log_rewatch', {
                              'viewing_id': const Uuid().v4(),
                            }),
                          );
                        }
                      })
                : () => _apply(
                    TrackingCommand(title.id!, 'mark_movie_watched', {
                      'viewing_id': const Uuid().v4(),
                      'wanted_revision': state.revision,
                    }),
                  ),
            child: Text(state.viewings > 0 ? 'Log rewatch' : 'Mark watched'),
          )
        : !isMovie
        ? _showAction(title.id!, state)
        : null;
    final wanted = state != null && state.viewings == 0 && state.intent == null
        ? OutlinedButton(
            onPressed: _pending
                ? null
                : () => _apply(
                    TrackingCommand(title.id!, 'set_wanted', {
                      'wanted': !state.wanted,
                      'wanted_revision': state.revision,
                    }),
                  ),
            child: Text(state.wanted ? 'Remove from Wanted' : 'Add to Wanted'),
          )
        : null;
    return Scaffold(
      appBar: AppBar(actions: [
        if (title.id case final id?)
          IconButton(tooltip: 'Copy title link', icon: const Icon(Icons.ios_share), onPressed: () async {
            await Clipboard.setData(ClipboardData(text: '$backendUrl/functions/v1/share/title/$id'));
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
          }),
      ]),
      body: ListView(
        children: [
          if (title.backdrop != null)
            SizedBox(
              height: isMovie ? 224 : 160,
              child: Artwork(title.backdrop, backdrop: true),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 72,
                      height: 108,
                      child: Artwork(title.poster),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title.name, style: theme.textTheme.displaySmall),
                          if (title.originalTitle != null &&
                              title.originalTitle != title.name)
                            Text(title.originalTitle!),
                          Text(
                            [
                              title.caption,
                              if (title.runtime case final minutes?)
                                '$minutes min',
                              if (title.genres.isNotEmpty) title.genres.first,
                            ].join(' · '),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (title.overview case final overview?) Text(overview),
                if (title.details['trailer'] case final String key)
                  TextButton.icon(onPressed: () async {
                    final opened = await launchUrl(Uri.https('www.youtube.com', '/watch', {'v': key}), mode: LaunchMode.externalApplication);
                    if (!opened && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the trailer.')));
                  }, icon: const Icon(Icons.play_arrow), label: const Text('Watch trailer')),
                if (title.id case final id?)
                  OpinionActions(title: id, label: isMovie ? 'movie' : 'show'),
                if (title.id case final id?)
                  FollowedRecommendations(titleId:id),
                if (!isMovie && state != null && state.statusLabel != null) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.statusLabel!,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Show status',
                        onSelected: (value) =>
                            _setIntent(title.id!, state, value),
                        enabled: !_pending,
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'watching',
                            child: Text('Watching'),
                          ),
                          PopupMenuItem(
                            value: 'on_hold',
                            child: Text('On Hold'),
                          ),
                          PopupMenuItem(
                            value: 'dropped',
                            child: Text('Dropped'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Text(
                    '${state.watched} of ${state.released} known released episodes watched',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    '${state.seasonsCompleted} of ${state.seasonsReleased} released seasons complete',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (!state.coverage)
                    const Text('Season metadata is incomplete.'),
                  if (state.next case final next?)
                    Text('Next · S${next.season}E${next.number} ${next.title}'),
                  if (state.next == null && state.upcomingDay != null)
                    Text('Next release · ${state.upcomingDay}'),
                ],
                if (!isMovie && title.id != null)
                  ShowSeasons(
                    show: title,
                    tracking: state,
                    pending: _pending,
                    refreshTracking: _refresh,
                    apply: _apply,
                  ),
                if (state != null && state.viewings > 0) ...[
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _history,
                    child: const Text('Viewing history'),
                  ),
                ],
                if (_pending) const LinearProgressIndicator(),
                if (state?.syncStatus == 'pending')
                  Semantics(liveRegion: true, child: const Text('Pending sync')),
                if (state?.syncStatus == 'conflict') ...[
                  const Text('This offline change conflicts with the saved state. Review the current state before reapplying.'),
                  TextButton(onPressed: () => context.read<LibraryRepository>().discardConflict(title.id!), child: const Text('Dismiss pending change')),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 16),
                  Semantics(liveRegion: true, child: Text(error)),
                  if (_retry case final command?)
                    TextButton(
                      onPressed: () =>
                          _apply(command, undo: command.action == 'undo'),
                      child: const Text('Retry'),
                    ),
                  if (state == null)
                    TextButton(onPressed: _refresh, child: const Text('Retry')),
                ],
                for (final (key, label) in [('creators', isMovie ? 'Directed by' : 'Created by'), ('cast', 'Cast'), ('similar', 'Similar titles')])
                  if (title.details[key] case final List items when items.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(label, style: theme.textTheme.titleLarge),
                    for (final row in items.whereType<Map<String, dynamic>>())
                      if (key == 'similar') CatalogTitleTile(CatalogTitle.fromMap(row))
                      else CatalogPersonTile(personFromMap(row)),
                  ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: primary == null && wanted == null
          ? null
          : ColoredBox(
              color: surfaceColor,
              child: SafeArea(
                minimum: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: OverflowBar(
                  spacing: 8,
                  overflowSpacing: 8,
                  alignment: MainAxisAlignment.center,
                  children: [?primary, ?wanted],
                ),
              ),
            ),
    );
  }

  void _setIntent(String id, TrackingState state, String intent) => _apply(
    TrackingCommand(id, 'set_show_intent', {
      'show_revision': state.showRevision,
      'intent': intent,
    }),
  );

  Widget? _showAction(String id, TrackingState state) {
    if (state.intent == null && state.released > 0) {
      return FilledButton(
        onPressed: _pending
            ? null
            : () => _apply(
                TrackingCommand(id, 'start_show', {
                  'show_revision': state.showRevision,
                  'wanted_revision': state.revision,
                }),
              ),
        child: const Text('Start watching'),
      );
    }
    if (state.intent == 'on_hold' || state.intent == 'dropped') {
      return FilledButton(
        onPressed: _pending ? null : () => _setIntent(id, state, 'watching'),
        child: const Text('Resume watching'),
      );
    }
    if (state.next case final next?) {
      return FilledButton(
        onPressed: _pending
            ? null
            : () => _apply(
                TrackingCommand(id, 'set_episode_watched', {
                  'episode_id': next.id,
                  'revision': next.revision,
                  'watched': true,
                }),
              ),
        child: const Text('Mark next episode watched'),
      );
    }
    return null;
  }
}

class _ViewingHistory extends StatefulWidget {
  const _ViewingHistory({required this.repository, required this.titleId});
  final LibraryRepository repository;
  final String titleId;

  @override
  State<_ViewingHistory> createState() => _ViewingHistoryState();
}

class _ViewingHistoryState extends State<_ViewingHistory> {
  List<Viewing> _items = [];
  bool _more = true;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final rows = await widget.repository.history(
        widget.titleId,
        after: _items.lastOrNull,
      );
      if (mounted) {
        setState(() {
          _items = [..._items, ...rows];
          _more = rows.length == 20;
        });
      }
    } on Exception {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: FractionallySizedBox(
      heightFactor: .72,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Viewing history',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          for (final entry in _items)
            ListTile(
              title: Text(entry.day ?? 'Date unknown'),
              trailing: PopupMenuButton<String>(
                tooltip: 'Viewing actions',
                onSelected: (action) =>
                    Navigator.pop(context, (entry: entry, action: action)),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'edit_movie_viewing',
                    child: Text('Edit date'),
                  ),
                  PopupMenuItem(value: 'clear', child: Text('Clear date')),
                  PopupMenuItem(
                    value: 'delete_movie_viewing',
                    child: Text('Delete viewing'),
                  ),
                ],
              ),
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_failed) const Text('Could not load viewing history.'),
          if (_more && !_loading)
            TextButton(
              onPressed: _load,
              child: Text(_failed ? 'Retry' : 'Load more'),
            ),
        ],
      ),
    ),
  );
}

