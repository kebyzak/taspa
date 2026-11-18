import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../auth/auth_cubit.dart';
import '../../catalog/data/catalog_repository.dart';
import '../../catalog/presentation/artwork.dart';
import '../data/library_repository.dart';
import 'tracking_cubit.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    return account.phase == AccountPhase.ready
        ? _LibraryBody(key: ValueKey(account.userId))
        : Center(
            child: OutlinedButton(
              onPressed: () => context.push('/account', extra: '/library'),
              child: const Text('Sign in to view your library'),
            ),
          );
  }
}

class _LibraryBody extends StatefulWidget {
  const _LibraryBody({super.key});

  @override
  State<_LibraryBody> createState() => _LibraryBodyState();
}

class _LibraryBodyState extends State<_LibraryBody> {
  LibrarySection _section = LibrarySection.watchedMovies;
  MediaKind? _filter;
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
    _changes = context.read<LibraryRepository>().changes.listen((_) => unawaited(_load()));
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
      if (!mounted || generation != _generation) return;
      setState(() {
        if (append) {
          final seen = _rows.map((row) => row.title.id).toSet();
          _rows = [..._rows, ...page.entries.where((entry) => seen.add(entry.title.id))];
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

  Future<void> _open(CatalogTitle title) async {
    await context.push(title.location);
    if (mounted) await _load();
  }

  Future<void> _track(LibraryEntry entry, String action) async {
    final id = entry.title.id!;
    final key = '$id:$action';
    final repo = context.read<LibraryRepository>();
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      var command = _pending[key];
      if (command == null) {
        final snapshot = entry.progress ?? await repo.snapshot(id);
        if (!mounted) return;
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
      await _load();
      if (!mounted) return;
      final undo = TrackingCommand(id, 'undo', {
        'original_operation_id': command.id,
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.state.syncStatus == 'pending' ? 'Change saved on this device. Pending sync.' : switch (action) {
            'set_episode_watched' => 'Episode marked watched',
            'start_show' => 'Started watching',
            'set_wanted' => 'Removed from Wanted',
            _ => 'Marked watched',
          }),
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

  void _select(LibrarySection section) {
    if (_section == section) return;
    setState(() {
      _section = section;
      _sort = LibrarySort.activity;
      _genre = null;
      _status = null;
      _minimumRating = null;
      _rows = [];
      _more = false;
    });
    _load();
  }

  Future<void> _sortAndFilter() async {
    var sort = _sort;
    var genre = _genre;
    var status = _status;
    var minimum = _minimumRating;
    final movie = _section == LibrarySection.watchedMovies;
    final show = _section == LibrarySection.watchedShows;
    final applied = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, update) => SafeArea(
        child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<LibrarySort>(initialValue: sort, decoration: const InputDecoration(labelText: 'Sort by'),
              items: [
                for (final (mode,label) in [
                  (LibrarySort.activity, !show && !movie ? 'Newest added' : 'Recent activity'),
                  (LibrarySort.title, 'Title'),
                  if (movie) (LibrarySort.viewing, 'Last viewing date'),
                  if (show || movie) (LibrarySort.rating, 'Personal rating'),
                  if (!show && !movie) (LibrarySort.release, 'Newest release'),
                ]) DropdownMenuItem(value: mode, child: Text(label)),
              ], onChanged: (value) => update(() => sort = value ?? LibrarySort.activity)),
            if (movie) ...[
              DropdownButtonFormField<String>(initialValue: genre ?? '', decoration: const InputDecoration(labelText: 'Genre'),
                items: [for (final item in const ['', 'Action', 'Adventure', 'Animation', 'Comedy', 'Crime', 'Documentary',
                  'Drama', 'Family', 'Fantasy','History','Horror','Music','Mystery','Romance','Science Fiction','Thriller','War','Western'])
                    DropdownMenuItem(value: item, child: Text(item.isEmpty ? 'Any genre' : item))],
                onChanged: (value) => update(() => genre = value == '' ? null : value)),
              DropdownButtonFormField<int>(initialValue: minimum ?? 0, decoration: const InputDecoration(labelText: 'Minimum personal rating'),
                items: [for (var score = 0; score <= 10; score++)
                  DropdownMenuItem(value: score,child: Text(score == 0 ? 'Any rating' : '${score / 2} stars'))],
                onChanged: (value) => update(() => minimum = value == 0 ? null : value)),
            ],
            if (show)
              DropdownButtonFormField<String>(initialValue: status ?? '', decoration: const InputDecoration(labelText: 'Tracking status'),
                items: [for (final (value,label) in const [('', 'All statuses'), ('watching','Watching'), ('completed','Completed'),
                  ('on_hold','On Hold'),('dropped','Dropped')]) DropdownMenuItem(value: value, child: Text(label))],
                onChanged: (value) => update(() => status = value == '' ? null : value)),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(context,true), child: const Text('Apply')),
            TextButton(onPressed: () {
              sort = LibrarySort.activity;
              genre = null;
              status = null;
              minimum = null;
              Navigator.pop(context,true);
            }, child: const Text('Reset filters')),
          ],
        )),
      )),
    );
    if (!mounted || applied != true) return;
    setState(() {
      _sort = sort;
      _genre = genre;
      _status = status;
      _minimumRating = minimum;
      _rows = [];
      _more = false;
    });
    await _load();
  }

  Widget _row(LibraryEntry entry) {
    final title = entry.title;
    final progress = entry.progress;
    final next = progress?.next;
    final wanted = _section == LibrarySection.wanted;
    final busy = _busy.contains(title.id);
    final upcoming =
        title.releaseDay?.isAfter(DateUtils.dateOnly(DateTime.now())) ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(
              width: 48,
              height: 72,
              child: Artwork(title.poster),
            ),
            title: Text(title.name),
            subtitle: Text(
              [
                title.caption,
                if (entry.rating case final stars?) '${stars / 2} ★',
                ?entry.watchedOn,
                if (!wanted && progress?.statusLabel != null)
                  progress!.statusLabel!,
                if (!wanted && progress != null)
                  '${progress.watched} of ${progress.released} known episodes',
                if (!wanted && next == null && progress?.upcomingDay != null)
                  'Next release · ${progress!.upcomingDay}',
              ].join(' · '),
            ),
            onTap: () => _open(title),
            trailing: wanted
                ? PopupMenuButton<String>(
                    tooltip: 'Wanted actions',
                    enabled: !busy,
                    onSelected: (_) => _track(entry, 'set_wanted'),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove from Wanted'),
                      ),
                    ],
                  )
                : null,
          ),
          if (!wanted && next != null)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => _open(title),
                    child: Text(
                      'Next · S${next.season}E${next.number} ${next.title}',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => _track(entry, 'set_episode_watched'),
                    child: const Text('Mark watched'),
                  ),
                ],
              ),
            ),
          if (wanted && title.kind == MediaKind.movie && !upcoming)
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => _track(entry, 'mark_movie_watched'),
              child: const Text('Mark watched'),
            ),
          if (wanted && (progress?.released ?? 0) > 0)
            OutlinedButton(
              onPressed: busy ? null : () => _track(entry, 'start_show'),
              child: const Text('Start watching'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.textScalerOf(context).scale(16) <= 21;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (section, label) in const [
                (LibrarySection.watchedMovies, 'Watched Movies'),
                (LibrarySection.watchedShows, 'Watched Shows'),
                (LibrarySection.wanted, 'Wanted'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: section == _section,
                  onSelected: (_) => _select(section),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerRight,
            child: TextButton.icon(onPressed: _sortAndFilter,
              icon: const Icon(Icons.tune), label: const Text('Sort and filter'))),
          if (_section == LibrarySection.wanted)
            Wrap(
              spacing: 8,
              children: [
                for (final (kind, label) in const [
                  (null, 'All'),
                  (MediaKind.movie, 'Movies'),
                  (MediaKind.show, 'Shows'),
                ])
                  ChoiceChip(
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
              ],
            ),
          if (_section == LibrarySection.watchedMovies)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => setState(() => _grid = !_grid),
                icon: Icon(
                  _grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
                ),
                label: Text(_grid ? 'List view' : 'Grid view'),
              ),
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_offline) const Text('Offline · showing saved library'),
          if (_waiting.isNotEmpty)
            Text('${_waiting.where((item) => !item.conflict).length} changes pending sync'),
          for (final item in _waiting.where((item) => item.conflict))
            ListTile(
              title: const Text('An offline tracking change needs attention'),
              onTap: () => context.push('/shared-title/${item.command.titleId}'),
              trailing: TextButton(
                onPressed: () => context.read<LibraryRepository>().discardConflict(item.command.titleId),
                child: const Text('Dismiss'),
              ),
            ),
          if (_failed)
            TextButton(
              onPressed: _load,
              child: const Text('Could not load library. Retry'),
            ),
          if (!_loading && !_failed && _rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  Text(switch (_section) {
                    LibrarySection.watchedMovies => 'No watched movies yet.',
                    LibrarySection.watchedShows => 'No tracked shows yet.',
                    LibrarySection.wanted => 'Nothing in Wanted yet.',
                  }),
                  if (_genre != null || _status != null || _minimumRating != null || _filter != null)
                    TextButton(onPressed: () {
                      setState(() { _filter = null; _genre = null; _status = null; _minimumRating = null; });
                      _load();
                    }, child: const Text('Clear filters')),
                  TextButton(
                    onPressed: () => context.push('/search'),
                    child: const Text('Search titles'),
                  ),
                ],
              ),
            ),
          if (_section == LibrarySection.watchedMovies && _grid && compact)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
                childAspectRatio: .48,
              ),
              itemCount: _rows.length,
              itemBuilder: (context, index) {
                final title = _rows[index].title;
                return InkWell(
                  onTap: () => _open(title),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Artwork(title.poster)),
                      const SizedBox(height: 4),
                      Text(
                        title.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            )
          else if (_section == LibrarySection.watchedShows &&
              _rows.isNotEmpty) ...[
            if (_rows.any((entry) => entry.progress?.next != null)) ...[
              Text(
                'Continue Watching',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final entry in _rows.where(
                (entry) => entry.progress?.next != null,
              ))
                _row(entry),
            ],
            if (_rows.any((entry) => entry.progress?.next == null)) ...[
              const SizedBox(height: 16),
              Text(
                'All other tracked shows',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final entry in _rows.where(
                (entry) => entry.progress?.next == null,
              ))
                _row(entry),
            ],
          ] else
            for (final entry in _rows) _row(entry),
          if (_more)
            TextButton(
              onPressed: _loading ? null : () => _load(append: true),
              child: const Text('Load more'),
            ),
        ],
      ),
    );
  }
}

