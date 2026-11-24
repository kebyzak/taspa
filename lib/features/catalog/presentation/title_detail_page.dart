import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../auth/auth_cubit.dart';
import '../../library/data/library_repository.dart';
import '../../library/presentation/tracking_cubit.dart';
import '../../social/presentation/reviews.dart';
import '../data/catalog_repository.dart';
import 'artwork.dart';
import 'discover_page.dart';
import 'share_card.dart';
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
          body: !snapshot.hasError
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: const [Skeleton(rows: 4, hero: 220)],
                )
              : Center(
                  child: Column(
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
                  ),
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
          persist: false,
          action: canUndo
              ? SnackBarAction(
                  label: 'Undo',
                  onPressed: () {
                    final revert = TrackingCommand(command.titleId, 'undo', {
                      'original_operation_id': command.id,
                    });
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
      switchToInputEntryModeIcon: const Icon(PhosphorIconsRegular.pencilSimple),
      switchToCalendarEntryModeIcon: const Icon(
        PhosphorIconsRegular.calendarBlank,
      ),
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

  Future<void> _openTrailer(String key) async {
    final opened = await launchUrl(
      Uri.https('www.youtube.com', '/watch', {'v': key}),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the trailer.')),
      );
    }
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
        if (title.details['rating'] case final Map<String, dynamic> rating) ...[
          const SizedBox(height: 8),
          ExternalRatingChip(rating),
        ],
      ],
    );
    final trailer = title.details['trailer'] as String?;
    final poster = SizedBox(
      width: 104,
      height: 156,
      child: trailer == null
          ? Artwork(title.poster, radius: 12)
          : Semantics(
              button: true,
              label: 'Watch trailer',
              excludeSemantics: true,
              child: GestureDetector(
                onTap: () => _openTrailer(trailer),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Artwork(title.poster, radius: 12),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: canvasColor.withValues(alpha: .6),
                          border: Border.all(
                            color: inkColor.withValues(alpha: .7),
                          ),
                        ),
                        child: const Icon(
                          PhosphorIconsFill.play,
                          size: 12,
                          color: inkColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
                      Color(0x9912161c),
                      Color(0x0012161c),
                      Color(0x8012161c),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                state.statusLabel!,
                style: theme.textTheme.titleMedium,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Change show status',
              icon: const Icon(PhosphorIconsRegular.dotsThree),
              enabled: !_pending,
              onSelected: (value) => _setIntent(id, state, value),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'watching', child: Text('Watching')),
                PopupMenuItem(value: 'on_hold', child: Text('On Hold')),
                PopupMenuItem(value: 'dropped', child: Text('Dropped')),
              ],
            ),
          ],
        ),
        if (state.released > 0)
          LinearProgressIndicator(
            value: state.watched / state.released,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            semanticsLabel: 'Episodes watched',
            semanticsValue: '${state.watched} of ${state.released}',
          ),
        const SizedBox(height: 6),
        Text(
          [
            '${state.watched} of ${state.released} episodes',
            '${state.seasonsCompleted} of ${state.seasonsReleased} seasons',
            if (state.next == null && state.upcomingDay != null)
              'Next release ${readableDay(state.upcomingDay!)}',
            if (!state.coverage) 'Season data incomplete',
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
      ],
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
          if (state != null && state.viewings > 0)
            IconButton(
              tooltip:
                  'Viewing history, ${state.viewings} ${state.viewings == 1 ? 'viewing' : 'viewings'}',
              icon: const Icon(PhosphorIconsRegular.clockCounterClockwise),
              onPressed: _history,
            ),
          if (title.id != null)
            IconButton(
              tooltip: 'Share',
              icon: const Icon(PhosphorIconsRegular.export),
              onPressed: () => shareTitle(context, title),
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
                if (!isMovie && state != null && state.statusLabel != null) ...[
                  const SizedBox(height: 12),
                  _showProgress(title.id!, state),
                ],
                if (title.id case final id?)
                  OpinionActions(
                    title: id,
                    label: isMovie ? 'movie' : 'show',
                    movie: isMovie,
                    showReviews: false,
                    tiles: false,
                  ),
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
            const SizedBox(height: 16),
            const SectionHeader('Cast and crew'),
            SizedBox(
              height: 136,
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
          if (title.id case final id?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TitleReviews(title: id),
            ),
          if (similar.isNotEmpty) ...[
            const SizedBox(height: 12),
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
            color: Color(0xffd5dce4),
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
              title: Text(
                entry.day == null ? 'Date unknown' : readableDay(entry.day!),
              ),
              trailing: PopupMenuButton<String>(
                tooltip: 'Viewing actions',
                icon: const Icon(PhosphorIconsRegular.dotsThree),
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
          if (_loading) const Skeleton(rows: 2, leading: 28),
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
