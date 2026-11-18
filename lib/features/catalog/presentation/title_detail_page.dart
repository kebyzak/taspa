import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../app/phosphor.dart';
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
    return id == null
        ? catalog.detail(widget.kind!, widget.tmdbId!)
        : catalog.sharedTitle(id);
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
                        onPressed: () => setState(() {
                          _title = _load();
                        }),
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
    if (_pending || !mounted) return;
    final repo = context.read<LibraryRepository>();
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
                : _tracking?.state?.syncStatus == 'pending'
                ? 'Change saved on this device. Pending sync.'
                : switch (command.action) {
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
                          ? 'Added to Want'
                          : 'Removed from Want',
                    _ => 'Viewing updated',
                  },
          ),
          action: canUndo
              ? SnackBarAction(
                  label: 'Undo',
                  onPressed: () {
                    final revert = TrackingCommand(command.titleId, 'undo', {
                      'original_operation_id': command.id,
                    });
                    // The snackbar outlives this page; after leaving it, undo through the repository directly.
                    if (mounted) {
                      _apply(revert, undo: true);
                    } else {
                      unawaited(
                        repo.undo(revert).then((_) {}, onError: (Object _) {}),
                      );
                    }
                  },
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
          useRootNavigator: true,
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

  Future<void> _rewatch() async {
    final dated = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Log rewatch',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(PhosphorIconsRegular.calendarBlank),
                label: const Text('Choose viewing date'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Save without date'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || dated == null) return;
    if (dated) {
      await _dateAction('log_rewatch');
    } else {
      await _apply(
        TrackingCommand(widget.title.id!, 'log_rewatch', {
          'viewing_id': const Uuid().v4(),
        }),
      );
    }
  }

  Widget _hero(CatalogTitle title, bool isMovie) {
    final theme = Theme.of(context);
    final creators = [
      for (final row
          in (title.details['creators'] as List? ?? const [])
              .whereType<Map<String, dynamic>>())
        row['name'] as String,
    ];
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title.name, style: theme.textTheme.displaySmall),
        if (title.originalTitle != null && title.originalTitle != title.name)
          Text(title.originalTitle!, style: const TextStyle(color: mutedColor)),
        const SizedBox(height: 4),
        Text(
          [
            title.caption,
            if (title.runtime case final minutes?) '$minutes min',
            if (title.genres.isNotEmpty) title.genres.first,
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
        if (creators.isNotEmpty)
          Text(
            '${isMovie ? 'Directed by' : 'Created by'} ${creators.take(2).join(', ')}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
    final poster = SizedBox(
      width: 104,
      height: 156,
      child: Artwork(title.poster, radius: 12),
    );
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight;
    if (title.backdrop == null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, top + 8, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            poster,
            const SizedBox(width: 16),
            Expanded(child: info),
          ],
        ),
      );
    }
    final height = (isMovie ? 224.0 : 180.0) + top;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Artwork(title.backdrop, backdrop: true),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, .3, .65, 1],
                    colors: [
                      Color(0x99141416),
                      Color(0x00141416),
                      Color(0x80141416),
                      canvasColor,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, height - 96, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              poster,
              const SizedBox(width: 16),
              Expanded(child: info),
            ],
          ),
        ),
      ],
    );
  }

  Widget _showProgress(String id, TrackingState state) {
    final theme = Theme.of(context);
    final value = state.released == 0 ? null : state.watched / state.released;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    state.statusLabel!,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Change show status',
                  enabled: !_pending,
                  onSelected: (value) => _setIntent(id, state, value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'watching', child: Text('Watching')),
                    PopupMenuItem(value: 'on_hold', child: Text('On Hold')),
                    PopupMenuItem(value: 'dropped', child: Text('Dropped')),
                  ],
                  child: const Chip(
                    label: Text('Status'),
                    avatar: Icon(PhosphorIconsRegular.caretDown, size: 18),
                    backgroundColor: pressedColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (value != null) ...[
              LinearProgressIndicator(
                value: value,
                semanticsLabel: 'Episodes watched',
                semanticsValue: '${state.watched} of ${state.released}',
              ),
              const SizedBox(height: 8),
            ],
            Text(
              '${state.watched} of ${state.released} episodes · ${state.seasonsCompleted} of ${state.seasonsReleased} seasons',
              style: theme.textTheme.bodySmall,
            ),
            if (!state.coverage)
              Text(
                'Season metadata is incomplete.',
                style: theme.textTheme.bodySmall,
              ),
            if (state.next case final next?) ...[
              const SizedBox(height: 8),
              Text(
                'Next · S${next.season}E${next.number} ${next.title}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: coralColor,
                ),
              ),
            ],
            if (state.next == null && state.upcomingDay != null) ...[
              const SizedBox(height: 8),
              Text(
                'Next release · ${state.upcomingDay}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _content(TrackingState? state) {
    final title = widget.title;
    final isMovie = title.kind == MediaKind.movie;
    final release = title.releaseDay;
    final upcoming =
        release != null && release.isAfter(DateUtils.dateOnly(DateTime.now()));
    final primary = !widget.ready
        ? FilledButton(
            onPressed: () => context.push('/account', extra: title.location),
            child: const Text('Sign in to track'),
          )
        : state == null
        ? null
        : isMovie && !upcoming
        ? FilledButton.icon(
            onPressed: _pending
                ? null
                : state.viewings > 0
                ? _rewatch
                : () => _apply(
                    TrackingCommand(title.id!, 'mark_movie_watched', {
                      'viewing_id': const Uuid().v4(),
                      'wanted_revision': state.revision,
                    }),
                  ),
            icon: Icon(
              state.viewings > 0
                  ? PhosphorIconsRegular.arrowCounterClockwise
                  : PhosphorIconsBold.check,
            ),
            label: Text(state.viewings > 0 ? 'Log rewatch' : 'Mark watched'),
          )
        : !isMovie
        ? _showAction(title.id!, state)
        : null;
    void toggleWanted() => _apply(
      TrackingCommand(title.id!, 'set_wanted', {
        'wanted': !state!.wanted,
        'wanted_revision': state.revision,
      }),
    );
    final canWant =
        state != null && state.viewings == 0 && state.intent == null;
    final isWanted = state?.wanted == true;
    final wantedLabel = isWanted ? 'Remove from Want' : 'Add to Want';
    final wanted = !canWant
        ? null
        : primary == null
        ? OutlinedButton.icon(
            onPressed: _pending ? null : toggleWanted,
            icon: Icon(
              isWanted
                  ? PhosphorIconsFill.bookmarkSimple
                  : PhosphorIconsRegular.bookmarkSimple,
            ),
            label: Text(wantedLabel),
          )
        : IconButton.outlined(
            tooltip: wantedLabel,
            isSelected: isWanted,
            onPressed: _pending ? null : toggleWanted,
            style: IconButton.styleFrom(
              minimumSize: const Size(52, 52),
              side: const BorderSide(color: hairlineColor),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(PhosphorIconsRegular.bookmarkSimple),
            selectedIcon: const Icon(
              PhosphorIconsFill.bookmarkSimple,
              color: coralColor,
            ),
          );
    List<Map<String, dynamic>> rows(String key) =>
        (title.details[key] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
    final people = [
      ...rows('creators'),
      ...rows('cast'),
    ].map(personFromMap).toList();
    final similar = rows('similar').map(CatalogTitle.fromMap).toList();
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          if (title.id case final id?)
            IconButton(
              tooltip: 'Copy title link',
              icon: const Icon(PhosphorIconsRegular.export),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: '$backendUrl/functions/v1/share/title/$id',
                  ),
                );
                if (mounted)
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Link copied')));
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _hero(title, isMovie),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_pending)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (state?.syncStatus == 'pending')
                  const InlineNotice(
                    'Pending sync',
                    icon: PhosphorIconsRegular.arrowsClockwise,
                  ),
                if (state?.syncStatus == 'conflict')
                  InlineNotice(
                    'This offline change conflicts with the saved state.',
                    icon: PhosphorIconsRegular.warning,
                    action: 'Dismiss',
                    onAction: () => context
                        .read<LibraryRepository>()
                        .discardConflict(title.id!),
                  ),
                if (_error case final error?)
                  InlineNotice(
                    error,
                    icon: PhosphorIconsRegular.warningCircle,
                    action: _retry != null || state == null ? 'Retry' : null,
                    onAction: () {
                      if (_retry case final command?) {
                        _apply(command, undo: command.action == 'undo');
                      } else {
                        _refresh();
                      }
                    },
                  ),
                if (title.overview case final overview?
                    when overview.isNotEmpty)
                  _Overview(overview),
                if (title.details['trailer'] case final String key)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ActionChip(
                      avatar: const Icon(
                        PhosphorIconsFill.play,
                        color: coralColor,
                      ),
                      label: const Text('Watch trailer'),
                      onPressed: () async {
                        final opened = await launchUrl(
                          Uri.https('www.youtube.com', '/watch', {'v': key}),
                          mode: LaunchMode.externalApplication,
                        );
                        if (!opened && mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Could not open the trailer.'),
                            ),
                          );
                      },
                    ),
                  ),
                if (!isMovie && state != null && state.statusLabel != null) ...[
                  const SizedBox(height: 24),
                  _showProgress(title.id!, state),
                ],
                if (title.id case final id?)
                  OpinionActions(
                    title: id,
                    label: isMovie ? 'movie' : 'show',
                    external: title.details['rating'] as Map<String, dynamic>?,
                  ),
                if (state != null && state.viewings > 0) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      leading: const Icon(
                        PhosphorIconsRegular.clockCounterClockwise,
                      ),
                      title: const Text('Viewing history'),
                      subtitle: Text(
                        '${state.viewings} ${state.viewings == 1 ? 'viewing' : 'viewings'}',
                      ),
                      trailing: const Icon(PhosphorIconsRegular.caretRight),
                      onTap: _history,
                    ),
                  ),
                ],
                if (title.id case final id?)
                  FollowedRecommendations(titleId: id),
                if (!isMovie && title.id != null)
                  ShowSeasons(
                    show: title,
                    tracking: state,
                    pending: _pending,
                    refreshTracking: _refresh,
                    apply: _apply,
                  ),
              ],
            ),
          ),
          if (people.isNotEmpty) ...[
            const SizedBox(height: 24),
            const SectionHeader('Cast and crew'),
            SizedBox(
              height: 148,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: people.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) => SizedBox(
                  width: 80,
                  child: CatalogPersonAvatar(people[index]),
                ),
              ),
            ),
          ],
          if (similar.isNotEmpty) ...[
            const SizedBox(height: 16),
            const SectionHeader('Similar titles'),
            Shelf(
              children: [
                for (final item in similar)
                  PosterCard(
                    poster: item.poster,
                    title: item.name,
                    caption: item.caption,
                    onTap: () => context.push(item.location),
                  ),
              ],
            ),
          ],
        ],
      ),
      bottomNavigationBar: primary == null && wanted == null
          ? null
          : DecoratedBox(
              decoration: const BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  children: [
                    if (primary != null) Expanded(child: primary),
                    if (primary != null && wanted != null)
                      const SizedBox(width: 8),
                    if (wanted != null)
                      primary == null ? Expanded(child: wanted) : wanted,
                  ],
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
        child: Text('Mark S${next.season}E${next.number} watched'),
      );
    }
    return null;
  }
}

class _Overview extends StatefulWidget {
  const _Overview(this.text);
  final String text;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => setState(() => _open = !_open),
    borderRadius: BorderRadius.circular(8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          maxLines: _open ? null : 4,
          overflow: _open ? null : TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 15,
            height: 1.5,
            color: Color(0xffd9d2cc),
          ),
        ),
        if (!_open && widget.text.length > 220)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'More',
              style: TextStyle(fontWeight: FontWeight.w600, color: coralColor),
            ),
          ),
      ],
    ),
  );
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
