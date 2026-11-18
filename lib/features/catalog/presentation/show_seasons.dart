import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../library/data/library_repository.dart';
import '../../social/presentation/reviews.dart';
import '../data/catalog_repository.dart';

class ShowSeasons extends StatefulWidget {
  const ShowSeasons({
    super.key,
    required this.show,
    required this.tracking,
    required this.pending,
    required this.refreshTracking,
    required this.apply,
  });

  final CatalogTitle show;
  final TrackingState? tracking;
  final bool pending;
  final Future<void> Function() refreshTracking;
  final Future<void> Function(TrackingCommand) apply;

  @override
  State<ShowSeasons> createState() => _ShowSeasonsState();
}

class _ShowSeasonsState extends State<ShowSeasons> {
  List<CatalogSeason> _seasons = [];
  CatalogSeason? _selected;
  List<CatalogEpisode> _episodes = [];
  int _version = 0;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadSeasons();
  }

  @override
  void didUpdateWidget(ShowSeasons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tracking != widget.tracking &&
        !_loading &&
        _selected != null) {
      _load(_selected!, hydrate: false);
    }
  }

  Future<void> _loadSeasons() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final seasons = await context.read<CatalogRepository>().seasons(
        widget.show.id!,
      );
      if (!mounted) return;
      setState(() => _seasons = seasons);
      final first =
          seasons.where((season) => season.number > 0).firstOrNull ??
          seasons.firstOrNull;
      if (first != null) {
        await _load(first);
      } else {
        setState(() => _loading = false);
      }
    } on Exception {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _load(CatalogSeason season, {bool hydrate = true}) async {
    final version = ++_version;
    final catalog = context.read<CatalogRepository>();
    setState(() {
      _loading = true;
      _failed = false;
      if (_selected != season) _episodes = [];
      _selected = season;
    });
    try {
      if (hydrate) {
        try {
          await catalog.hydrateSeason(widget.show.tmdbId, season.number);
        } on Exception {
          if (!season.loaded) rethrow;
        }
        await widget.refreshTracking();
      }
      final episodes = await catalog.episodes(widget.show.id!, season.id);
      if (mounted && version == _version) setState(() => _episodes = episodes);
    } on Exception {
      if (mounted && version == _version) setState(() => _failed = true);
    } finally {
      if (mounted && version == _version) setState(() => _loading = false);
    }
  }

  Future<void> _change(CatalogEpisode episode, String action) async {
    DateTime? picked;
    if (action == 'date') {
      final now = DateTime.now();
      picked = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: DateTime(1870),
        lastDate: now,
      );
      if (picked == null || !mounted) return;
    }
    await widget.apply(
      TrackingCommand(
        widget.show.id!,
        action == 'mark' || action == 'unwatch'
            ? 'set_episode_watched'
            : 'edit_episode_watch_date',
        {
          'episode_id': episode.id,
          'revision': episode.revision,
          if (action == 'mark' || action == 'unwatch')
            'watched': action == 'mark',
          if (picked != null)
            'watched_on': picked.toIso8601String().split('T').first,
          if (action == 'mark' && widget.tracking?.intent == null) ...{
            'wanted_revision': widget.tracking?.revision,
            'show_revision': widget.tracking?.showRevision,
          },
        },
      ),
    );
  }

  Future<void> _batch(
    String scope,
    String label, {
    String? season,
    String? episode,
  }) async {
    final tracking = widget.tracking;
    if (tracking == null || _loading || widget.pending) return;
    try {
      final preview = await context.read<LibraryRepository>().preview(
        widget.show.id!,
        scope,
        seasonId: season,
        episodeId: episode,
      );
      if (!mounted) return;
      final count = (preview['episodes'] as List).length;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(label),
          content: Text(
            '$count ${count == 1 ? 'episode' : 'episodes'} will change.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      await widget.apply(
        TrackingCommand(widget.show.id!, 'apply_show_batch', {
          'scope': scope,
          'season_id': ?season,
          'episode_id': ?episode,
          'episodes': preview['episodes'],
          'catalog_revision': preview['catalog_revision'],
          'show_revision': tracking.showRevision,
          'wanted_revision': tracking.revision,
        }),
      );
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not preview this change. Check the season data or select a smaller range.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selected;
    final tracked = widget.tracking;
    final released = _episodes.where((e) => e.released);
    final upcoming = _episodes.where((e) => !e.released);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text('Seasons', style: theme.textTheme.titleLarge),
        if (_seasons.isNotEmpty) ...[
          const SizedBox(height: 8),
          DropdownButton<String>(
            isExpanded: true,
            value: selected?.id,
            hint: const Text('Choose season'),
            items: [
              for (final season in _seasons)
                DropdownMenuItem(
                  value: season.id,
                  child: Text(
                    season.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) =>
                _load(_seasons.firstWhere((season) => season.id == id)),
          ),
        ],
        if (_loading) const LinearProgressIndicator(),
        if (_failed)
          TextButton(
            onPressed: selected == null ? _loadSeasons : () => _load(selected),
            child: const Text('Could not load episodes. Retry'),
          ),
        if (!_loading && !_failed && _seasons.isEmpty)
          const Text('Season information is unavailable.'),
        if (selected != null && widget.show.id != null)
          OpinionActions(
            key: ValueKey(selected.id),
            title: widget.show.id!,
            season: selected.id,
            label: 'season',
          ),
        if (tracked != null && released.isNotEmpty)
          Text(
            '${released.where((e) => e.watched).length} of ${released.length} released episodes watched',
            style: theme.textTheme.bodySmall,
          ),
        if (tracked != null)
          Wrap(
            spacing: 8,
            children: [
              if ((selected?.number ?? 0) > 0) ...[
                TextButton(
                  onPressed: _loading || widget.pending
                      ? null
                      : () => _batch(
                          'mark_season_watched',
                          'Mark released episodes watched?',
                          season: selected!.id,
                        ),
                  child: const Text('Mark season watched'),
                ),
                if (tracked.intent != null)
                  TextButton(
                    onPressed: _loading || widget.pending
                        ? null
                        : () => _batch(
                            'mark_season_unwatched',
                            'Mark this season unwatched?',
                            season: selected!.id,
                          ),
                    child: const Text('Mark season unwatched'),
                  ),
              ],
              if (tracked.intent != null)
                TextButton(
                  onPressed: _loading || widget.pending
                      ? null
                      : () => _batch('remove_show', 'Remove show tracking?'),
                  child: const Text('Remove show tracking'),
                ),
              if (['Ended','Canceled'].contains(widget.show.releaseStatus))
                TextButton(
                  onPressed: _loading || widget.pending
                      ? null
                      : () => _batch('mark_ended_show_watched', 'Mark all released episodes watched?'),
                  child: const Text('Mark all released episodes watched'),
                ),
            ],
          ),
        for (final episode in released)
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap:
                tracked != null &&
                    !widget.pending &&
                    (selected?.number ?? 0) > 0
                ? () => _batch(
                    'mark_through',
                    'Mark through episode ${episode.number}?',
                    episode: episode.id,
                  )
                : null,
            title: Text('E${episode.number}  ${episode.title}'),
            subtitle: Text(
              episode.watched
                  ? 'Watched · ${episode.watchedOn ?? 'Date unknown'}'
                  : 'Unwatched',
            ),
            trailing: tracked == null || widget.pending
                ? null
                : episode.watched
                ? PopupMenuButton<String>(
                    tooltip: 'Episode actions',
                    onSelected: (value) => _change(episode, value),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'date',
                        child: Text('Edit watch date'),
                      ),
                      PopupMenuItem(value: 'clear', child: Text('Clear date')),
                      PopupMenuItem(
                        value: 'unwatch',
                        child: Text('Mark unwatched'),
                      ),
                    ],
                  )
                : tracked.intent != null || (selected?.number ?? 0) > 0
                ? IconButton(
                    tooltip: 'Mark episode ${episode.number} watched',
                    onPressed: () => _change(episode, 'mark'),
                    icon: const Icon(Icons.check_circle_outline),
                  )
                : null,
          ),
        if (upcoming.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Upcoming', style: theme.textTheme.titleMedium),
          for (final episode in upcoming)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('E${episode.number}  ${episode.title}'),
              subtitle: Text(episode.releaseDay ?? 'Release date unknown'),
            ),
        ],
      ],
    );
  }
}
