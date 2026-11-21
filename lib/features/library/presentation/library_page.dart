import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../auth/auth_cubit.dart';
import '../../catalog/data/catalog_repository.dart';
import '../../catalog/presentation/artwork.dart';
import '../../catalog/presentation/discover_page.dart';
import '../data/library_repository.dart';
import 'tracking_cubit.dart';

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key, this.movies = false});

  final bool movies;

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  late int _index = widget.movies ? 1 : 0;
  late final _visited = {_index};

  @override
  void didUpdateWidget(LibraryTab old) {
    super.didUpdateWidget(old);
    if (old.movies != widget.movies) {
      _index = widget.movies ? 1 : 0;
      _visited.add(_index);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Row(
          children: [
            for (final (index, label) in const [(0, 'Shows'), (1, 'Movies')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(label),
                  selected: _index == index,
                  onSelected: (_) =>
                      setState(() => _visited.add(_index = index)),
                ),
              ),
          ],
        ),
      ),
      Expanded(
        child: IndexedStack(
          index: _index,
          children: [
            const LibraryPage(section: LibrarySection.watchedShows),
            _visited.contains(1)
                ? const LibraryPage(
                    section: LibrarySection.wanted,
                    media: MediaKind.movie,
                  )
                : const SizedBox.shrink(),
          ],
        ),
      ),
    ],
  );
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key, required this.section, this.media});

  final LibrarySection section;
  final MediaKind? media;

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    return account.phase == AccountPhase.ready
        ? _LibraryBody(
            key: ValueKey((account.userId, section, media)),
            section: section,
            media: media,
          )
        : EmptyState(
            icon: section == LibrarySection.wanted
                ? PhosphorIconsRegular.bookmarkSimple
                : PhosphorIconsRegular.television,
            title: section == LibrarySection.wanted
                ? 'Keep a Want list'
                : 'Track your shows',
            message: 'Sign in to save titles and mark episodes as you watch.',
            action: FilledButton(
              onPressed: () => context.push('/account', extra: '/library'),
              child: const Text('Sign in'),
            ),
          );
  }
}

class _LibraryBody extends StatefulWidget {
  const _LibraryBody({super.key, required this.section, this.media});

  final LibrarySection section;
  final MediaKind? media;

  @override
  State<_LibraryBody> createState() => _LibraryBodyState();
}

class _LibraryBodyState extends State<_LibraryBody> {
  late final LibrarySection _section = widget.section;
  late MediaKind? _filter = widget.media;
  bool _showWant = true;
  bool _showUpToDate = true;
  List<LibraryEntry> _wantShows = [];
  LibraryEntry? _wantCursor;
  LibrarySort _sort = LibrarySort.activity;
  String? _genre;
  String? _status;
  int? _minimumRating;
  bool _grid = true;
  bool _more = false;
  bool _offline = false;
  LibraryEntry? _cursor;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;
  List<LibraryEntry> _rows = [];
  final _pending = <String, TrackingCommand>{};
  final _busy = <String>{};
  late final StreamSubscription<void> _changes;
  List<({TrackingCommand command, bool conflict})> _waiting = [];

  @override
  void initState() {
    super.initState();
    _changes = context.read<LibraryRepository>().changes.listen(
      (_) => unawaited(_load()),
    );
    _load();
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final repo = context.read<LibraryRepository>();
      final waiting = await repo.pendingChanges();
      if (!mounted || generation != _generation) return;
      setState(() => _waiting = waiting);
      final page = await repo.list(
        _section,
        media: _section == LibrarySection.wanted ? _filter : null,
        after: append ? _cursor : null,
        sort: _sort,
        genre: _genre,
        status: _status,
        minimumRating: _minimumRating,
      );
      final want =
          _section == LibrarySection.watchedShows && _showWant && !append
          ? await repo.list(LibrarySection.wanted, media: MediaKind.show)
          : null;
      if (!mounted || generation != _generation) return;
      setState(() {
        if (want != null) {
          _wantShows = want.entries;
          _wantCursor = want.cursor;
        } else if (!_showWant) {
          _wantShows = [];
          _wantCursor = null;
        }
        if (append) {
          final seen = _rows.map((row) => row.title.id).toSet();
          _rows = [
            ..._rows,
            ...page.entries.where((entry) => seen.add(entry.title.id)),
          ];
        } else {
          _rows = page.entries;
        }
        _cursor = page.cursor;
        _more = page.cursor != null;
        _offline = page.offline;
      });
    } on Exception {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _moreWant() async {
    try {
      final page = await context.read<LibraryRepository>().list(
        LibrarySection.wanted,
        media: MediaKind.show,
        after: _wantCursor,
      );
      if (!mounted) return;
      setState(() {
        final seen = _wantShows.map((row) => row.title.id).toSet();
        _wantShows = [
          ..._wantShows,
          ...page.entries.where((entry) => seen.add(entry.title.id)),
        ];
        _wantCursor = page.cursor;
      });
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trackingMessage(error))));
      }
    }
  }

  Future<void> _open(CatalogTitle title) async {
    await context.push(title.location);
    if (mounted) await _load();
  }

  Future<void> _track(LibraryEntry entry, String action) async {
    final id = entry.title.id!;
    final key = '$id:$action';
    final repo = context.read<LibraryRepository>();
    final catalog = context.read<CatalogRepository>();
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      var command = _pending[key];
      if (command == null) {
        var snapshot = entry.progress ?? await repo.snapshot(id);
        if (action == 'set_episode_watched' &&
            snapshot.next == null &&
            snapshot.pendingSeason != null) {
          await catalog.hydrateSeason(
            entry.title.tmdbId,
            snapshot.pendingSeason!,
          );
          snapshot = await repo.snapshot(id);
        }
        if (!mounted) return;
        if (action == 'set_episode_watched' && snapshot.next == null) {
          throw const TrackingFailure('No released episode left to mark.');
        }
        command = TrackingCommand(id, action, switch (action) {
          'set_episode_watched' => {
            'episode_id': snapshot.next!.id,
            'revision': snapshot.next!.revision,
            'watched': true,
          },
          'start_show' => {
            'show_revision': snapshot.showRevision,
            'wanted_revision': snapshot.revision,
          },
          'set_wanted' => {
            'wanted': false,
            'wanted_revision': snapshot.revision,
          },
          _ => {
            'viewing_id': const Uuid().v4(),
            'wanted_revision': snapshot.revision,
          },
        });
        _pending[key] = command;
      }
      final result = await repo.apply(command);
      _pending.remove(key);
      if (!mounted) return;
      if (action == 'set_episode_watched') {
        setState(
          () => _rows = [
            for (final row in _rows)
              row.title.id == id
                  ? (
                      title: row.title,
                      activityAt: row.activityAt,
                      progress: result.state,
                      sortText: row.sortText,
                      sortValue: row.sortValue,
                      rating: row.rating,
                      watchedOn: row.watchedOn,
                    )
                  : row,
          ],
        );
        if (result.state.syncStatus == 'pending') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved on this device. Pending sync.'),
            ),
          );
        }
        return;
      }
      await _load();
      if (!mounted) return;
      final undo = TrackingCommand(id, 'undo', {
        'original_operation_id': command.id,
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.state.syncStatus == 'pending'
                ? 'Change saved on this device. Pending sync.'
                : switch (action) {
                    'set_episode_watched' => 'Episode marked watched',
                    'start_show' => 'Started watching',
                    'set_wanted' => 'Removed from Want',
                    _ => 'Marked watched',
                  },
          ),
          action: result.canUndo
              ? SnackBarAction(
                  label: 'Undo',
                  onPressed: () => _undo(repo, undo),
                )
              : null,
        ),
      );
    } on Exception catch (error) {
      if (isTrackingConflict(error)) _pending.remove(key);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trackingMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _undo(LibraryRepository repo, TrackingCommand command) async {
    try {
      await repo.undo(command);
      if (mounted) await _load();
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(trackingMessage(error)),
          action: isTrackingConflict(error)
              ? null
              : SnackBarAction(
                  label: 'Retry',
                  onPressed: () => _undo(repo, command),
                ),
        ),
      );
    }
  }

  Future<void> _sortAndFilter() async {
    var sort = _sort;
    var genre = _genre;
    var status = _status;
    var minimum = _minimumRating;
    var showWant = _showWant;
    var showUpToDate = _showUpToDate;
    final movie = _section == LibrarySection.watchedMovies;
    final show = _section == LibrarySection.watchedShows;
    Widget chips<T>(
      String label,
      List<(T, String)> options,
      T value,
      void Function(T) pick,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (option, text) in options)
              ChoiceChip(
                label: Text(text),
                selected: option == value,
                onSelected: (_) => pick(option),
              ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
    final applied = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Sort and filter',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                chips<LibrarySort>(
                  'Sort by',
                  [
                    (
                      LibrarySort.activity,
                      !show && !movie ? 'Newest added' : 'Recent activity',
                    ),
                    (LibrarySort.title, 'Title'),
                    if (movie) (LibrarySort.viewing, 'Last viewing'),
                    if (show || movie) (LibrarySort.rating, 'My rating'),
                    if (!show && !movie)
                      (LibrarySort.release, 'Newest release'),
                  ],
                  sort,
                  (value) => update(() => sort = value),
                ),
                if (show)
                  chips<String?>(
                    'Status',
                    const [
                      (null, 'All'),
                      ('watching', 'Watching'),
                      ('completed', 'Completed'),
                      ('on_hold', 'On Hold'),
                      ('dropped', 'Dropped'),
                    ],
                    status,
                    (value) => update(() => status = value),
                  ),
                if (show) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show Want list'),
                    subtitle: const Text(
                      'Shows you saved for later, below your tracked shows',
                    ),
                    value: showWant,
                    onChanged: (value) => update(() => showWant = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show up to date'),
                    subtitle: const Text(
                      'Shows with no released episode left to watch',
                    ),
                    value: showUpToDate,
                    onChanged: (value) => update(() => showUpToDate = value),
                  ),
                  const SizedBox(height: 16),
                ],
                if (movie) ...[
                  chips<int?>(
                    'My rating',
                    [
                      (null, 'Any'),
                      for (final score in [6, 7, 8, 9]) (score, '$score+'),
                    ],
                    minimum,
                    (value) => update(() => minimum = value),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: genre ?? '',
                    decoration: const InputDecoration(labelText: 'Genre'),
                    icon: const Icon(PhosphorIconsRegular.caretDown, size: 18),
                    items: [
                      for (final item in const [
                        '',
                        'Action',
                        'Adventure',
                        'Animation',
                        'Comedy',
                        'Crime',
                        'Documentary',
                        'Drama',
                        'Family',
                        'Fantasy',
                        'History',
                        'Horror',
                        'Music',
                        'Mystery',
                        'Romance',
                        'Science Fiction',
                        'Thriller',
                        'War',
                        'Western',
                      ])
                        DropdownMenuItem(
                          value: item,
                          child: Text(item.isEmpty ? 'Any genre' : item),
                        ),
                    ],
                    onChanged: (value) =>
                        update(() => genre = value == '' ? null : value),
                  ),
                  const SizedBox(height: 24),
                ],
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Apply'),
                ),
                TextButton(
                  onPressed: () {
                    sort = LibrarySort.activity;
                    genre = null;
                    status = null;
                    minimum = null;
                    showWant = true;
                    showUpToDate = true;
                    Navigator.pop(context, true);
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || applied != true) return;
    setState(() {
      _sort = sort;
      _genre = genre;
      _status = status;
      _minimumRating = minimum;
      _showWant = showWant;
      _showUpToDate = showUpToDate;
      _rows = [];
      _more = false;
    });
    await _load();
  }

  bool get _filtered =>
      _genre != null ||
      _status != null ||
      _minimumRating != null ||
      _filter != widget.media;

  bool _behind(TrackingState? progress) =>
      progress != null &&
      (progress.next != null ||
          (progress.intent == 'watching' && progress.pendingSeason != null));

  static final _smallAction = IconButton.styleFrom(
    minimumSize: const Size(32, 32),
    fixedSize: const Size(32, 32),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.padded,
  );
  static final _checkAction = _smallAction.copyWith(
    side: const WidgetStatePropertyAll(BorderSide(color: coralColor)),
  );

  Widget _showRow(LibraryEntry entry, {required bool dimmed}) {
    final title = entry.title;
    final progress = entry.progress;
    final next = progress?.next;
    final pending = next == null ? progress?.pendingSeason : null;
    final canMark = _behind(progress);
    final busy = _busy.contains(title.id);
    final value = progress == null || progress.released == 0
        ? null
        : progress.watched / progress.released;
    final subtitle = next != null
        ? 'S${next.season} E${next.number} · ${next.title}'
        : pending != null
        ? 'Season $pending · next episode'
        : [
            ?progress?.statusLabel,
            if (progress?.upcomingDay case final day?)
              'Next ${readableDay(day)}',
          ].join(' · ');
    final row = Card(
      child: InkWell(
        onTap: () => _open(title),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SizedBox(width: 56, height: 84, child: Artwork(title.poster)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: canMark ? inkColor : mutedColor,
                        ),
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: value == null
                              ? const SizedBox.shrink()
                              : LinearProgressIndicator(
                                  value: value,
                                  color: dimmed ? mutedColor : coralColor,
                                  semanticsLabel: 'Episodes watched',
                                  semanticsValue:
                                      '${progress!.watched} of ${progress.released}',
                                ),
                        ),
                        const SizedBox(width: 10),
                        if (progress != null)
                          Text(
                            '${progress.watched}/${progress.released}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (canMark)
                IconButton.outlined(
                  tooltip: next != null
                      ? 'Mark S${next.season}E${next.number} ${next.title} watched'
                      : 'Mark next episode watched',
                  onPressed: busy
                      ? null
                      : () => _track(entry, 'set_episode_watched'),
                  style: _checkAction,
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: coralColor,
                          ),
                        )
                      : const Icon(
                          PhosphorIconsRegular.check,
                          size: 12,
                          color: coralColor,
                        ),
                )
              else
                const SizedBox(
                  width: 48,
                  child: Icon(
                    PhosphorIconsRegular.checks,
                    size: 20,
                    color: mutedColor,
                    semanticLabel: 'Up to date',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: dimmed ? Opacity(opacity: .55, child: row) : row,
    );
  }

  Widget _row(LibraryEntry entry, {bool want = false}) {
    final title = entry.title;
    final progress = entry.progress;
    final wanted = want || _section == LibrarySection.wanted;
    final busy = _busy.contains(title.id);
    final release = title.releaseDay;
    final upcoming =
        release?.isAfter(DateUtils.dateOnly(DateTime.now())) ?? false;
    final meta = [
      title.caption,
      if (wanted && upcoming) 'Out ${readableDate(release!)}',
      if (entry.rating case final score?) '★ ${scoreText(score)}',
      if (entry.watchedOn case final day?) readableDay(day),
    ].join(' · ');
    Widget? action;
    if (wanted && title.kind == MediaKind.movie && !upcoming) {
      action = IconButton.outlined(
        tooltip: 'Mark ${title.name} watched',
        onPressed: busy ? null : () => _track(entry, 'mark_movie_watched'),
        style: _checkAction,
        icon: const Icon(
          PhosphorIconsRegular.check,
          size: 12,
          color: coralColor,
        ),
      );
    } else if (wanted && (progress?.released ?? 0) > 0) {
      action = IconButton.outlined(
        tooltip: 'Start watching ${title.name}',
        onPressed: busy ? null : () => _track(entry, 'start_show'),
        style: _checkAction,
        icon: const Icon(PhosphorIconsFill.play, size: 12, color: coralColor),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: InkWell(
          onTap: () => _open(title),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                SizedBox(width: 56, height: 84, child: Artwork(title.poster)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (meta.isNotEmpty)
                        Text(
                          meta,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (action != null) ...[const SizedBox(width: 8), action],
                if (wanted)
                  PopupMenuButton<String>(
                    tooltip: 'Want actions',
                    icon: const Icon(PhosphorIconsRegular.dotsThree),
                    enabled: !busy,
                    onSelected: (_) => _track(entry, 'set_wanted'),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove from Want'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.textScalerOf(context).scale(16) <= 21;
    final shows = _section == LibrarySection.watchedShows;
    final continuing = _rows.where((entry) => _behind(entry.progress)).toList();
    bool stopped(LibraryEntry entry) =>
        const {'on_hold', 'dropped'}.contains(entry.progress?.intent);
    final others = _rows
        .where((entry) => !_behind(entry.progress) && !stopped(entry))
        .toList();
    final stoppedShows = _rows.where(stopped).toList();
    final sheetFilters =
        _genre != null ||
        _status != null ||
        _minimumRating != null ||
        !_showWant ||
        !_showUpToDate;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          Row(
            children: [
              if (_section == LibrarySection.wanted && widget.media == null)
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (kind, label) in const [
                          (null, 'All'),
                          (MediaKind.movie, 'Movies'),
                          (MediaKind.show, 'Shows'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(label),
                              selected: _filter == kind,
                              onSelected: (_) {
                                setState(() {
                                  _filter = kind;
                                  _rows = [];
                                  _more = false;
                                });
                                _load();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: Text(
                    shows
                        ? (_rows.isEmpty
                              ? ''
                              : '${continuing.length} to watch · ${others.length} up to date')
                        : (_rows.isEmpty
                              ? ''
                              : '${_rows.length}${_more ? '+' : ''} ${_section == LibrarySection.wanted ? 'to watch' : 'movies'}'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              IconButton(
                tooltip: sheetFilters
                    ? 'Sort and filter, filters active'
                    : 'Sort and filter',
                onPressed: _sortAndFilter,
                icon: Badge(
                  isLabelVisible: sheetFilters,
                  smallSize: 8,
                  backgroundColor: coralColor,
                  child: const Icon(PhosphorIconsRegular.slidersHorizontal),
                ),
              ),
              if (_section == LibrarySection.watchedMovies)
                IconButton(
                  tooltip: _grid ? 'Show as list' : 'Show as grid',
                  onPressed: () => setState(() => _grid = !_grid),
                  icon: Icon(
                    _grid
                        ? PhosphorIconsRegular.rows
                        : PhosphorIconsRegular.squaresFour,
                  ),
                ),
            ],
          ),
          if (_loading && _rows.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(),
            ),
          if (_offline)
            const InlineNotice(
              'Offline · showing saved library',
              icon: PhosphorIconsRegular.cloudSlash,
            ),
          if (_waiting.any((item) => !item.conflict))
            InlineNotice(
              '${_waiting.where((item) => !item.conflict).length} changes pending sync',
              icon: PhosphorIconsRegular.arrowsClockwise,
            ),
          for (final item in _waiting.where((item) => item.conflict))
            InlineNotice(
              'An offline change needs attention',
              icon: PhosphorIconsRegular.warning,
              action: 'Review',
              onAction: () =>
                  context.push('/shared-title/${item.command.titleId}'),
            ),
          if (_failed)
            InlineNotice(
              'Could not load.',
              icon: PhosphorIconsRegular.warningCircle,
              action: 'Retry',
              onAction: _load,
            ),
          if (!_loading && !_failed && _rows.isEmpty && _wantShows.isEmpty)
            EmptyState(
              icon: switch (_section) {
                LibrarySection.watchedMovies => PhosphorIconsRegular.filmSlate,
                LibrarySection.watchedShows => PhosphorIconsRegular.television,
                LibrarySection.wanted => PhosphorIconsRegular.bookmarkSimple,
              },
              title: _filtered
                  ? 'Nothing matches'
                  : switch (_section) {
                      LibrarySection.watchedMovies => 'No watched movies yet',
                      LibrarySection.watchedShows => 'No shows yet',
                      LibrarySection.wanted =>
                        widget.media == MediaKind.movie
                            ? 'No movies in Want yet'
                            : 'Nothing in Want yet',
                    },
              message: _filtered
                  ? 'Try clearing the filters.'
                  : shows
                  ? 'Tap + to find a show and start tracking it episode by episode.'
                  : 'Tap + to find something to watch later.',
              action: _filtered
                  ? OutlinedButton(
                      onPressed: () {
                        setState(() {
                          _filter = widget.media;
                          _genre = null;
                          _status = null;
                          _minimumRating = null;
                        });
                        _load();
                      },
                      child: const Text('Clear filters'),
                    )
                  : FilledButton.icon(
                      onPressed: () => showSearchSheet(context),
                      icon: const Icon(PhosphorIconsBold.plus),
                      label: const Text('Add a title'),
                    ),
            ),
          if (_section == LibrarySection.watchedMovies && _grid && compact)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
                childAspectRatio: .5,
              ),
              itemCount: _rows.length,
              itemBuilder: (context, index) {
                final entry = _rows[index];
                return PosterCard(
                  poster: entry.title.poster,
                  title: entry.title.name,
                  caption: entry.watchedOn == null
                      ? entry.title.caption
                      : readableDay(entry.watchedOn!),
                  score: entry.rating,
                  onTap: () => _open(entry.title),
                );
              },
            )
          else if (!shows)
            for (final entry in _rows) _row(entry),
          if (shows)
            for (final entry in continuing) _showRow(entry, dimmed: false),
          if (shows && _showWant && _wantShows.isNotEmpty) ...[
            SectionHeader(
              'Want · ${_wantShows.length}${_wantCursor != null ? '+' : ''}',
              padding: EdgeInsets.only(
                top: continuing.isEmpty ? 0 : 24,
                bottom: 4,
              ),
            ),
            for (final entry in _wantShows) _row(entry, want: true),
            if (_wantCursor != null)
              OutlinedButton(
                onPressed: _moreWant,
                child: const Text('Load more'),
              ),
          ],
          if (shows && _showUpToDate && others.isNotEmpty) ...[
            if (continuing.isNotEmpty || (_showWant && _wantShows.isNotEmpty))
              const SectionHeader(
                'Up to date',
                padding: EdgeInsets.only(top: 24, bottom: 4),
              ),
            for (final entry in others) _showRow(entry, dimmed: true),
          ],
          if (shows && stoppedShows.isNotEmpty) ...[
            const SectionHeader(
              'On hold & dropped',
              padding: EdgeInsets.only(top: 24, bottom: 4),
            ),
            for (final entry in stoppedShows) _showRow(entry, dimmed: true),
          ],
          if (_more)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                onPressed: _loading ? null : () => _load(append: true),
                child: const Text('Load more'),
              ),
            ),
        ],
      ),
    );
  }
}
