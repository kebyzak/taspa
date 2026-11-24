import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../library/data/library_repository.dart';
import '../../social/presentation/reviews.dart';
import '../data/catalog_repository.dart';

Future<void> confirmShowBatch(
  BuildContext context, {
  required String showId,
  required TrackingState tracking,
  required Future<void> Function(TrackingCommand) apply,
  required String scope,
  required String question,
  String? season,
  String? episode,
}) async {
  try {
    final preview = await context.read<LibraryRepository>().preview(
      showId,
      scope,
      seasonId: season,
      episodeId: episode,
    );
    if (!context.mounted) return;
    final count = (preview['episodes'] as List).length;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(question),
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
    if (approved != true || !context.mounted) return;
    await apply(
      TrackingCommand(showId, 'apply_show_batch', {
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
    if (context.mounted) {
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

class ActionLink extends StatelessWidget {
  const ActionLink({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    excludeSemantics: true,
    label: label,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: coralColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: coralColor,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

typedef _Progress = ({int released, int watched});

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
  Map<String, _Progress> _progress = {};
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
      _loadProgress();
    }
  }

  Future<void> _loadProgress() async {
    try {
      final progress = await context.read<CatalogRepository>().seasonProgress(
        widget.show.id!,
      );
      if (mounted) setState(() => _progress = progress);
    } on Exception {
      // Progress only decorates the picker; the season list works without it.
    }
  }

  bool _unfinished(CatalogSeason season) {
    final p = _progress[season.id];
    return p == null || p.watched < p.released;
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
      await _loadProgress();
      if (!mounted) return;
      setState(() => _seasons = seasons);
      final numbered = seasons.where((season) => season.number > 0);
      final next = widget.tracking?.next?.season;
      final started = _progress.values.any((p) => p.watched > 0);
      final first =
          numbered.where((season) => season.number == next).firstOrNull ??
          (started ? numbered.where(_unfinished).firstOrNull : null) ??
          numbered.firstOrNull ??
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
        switchToInputEntryModeIcon: const Icon(
          PhosphorIconsRegular.pencilSimple,
        ),
        switchToCalendarEntryModeIcon: const Icon(
          PhosphorIconsRegular.calendarBlank,
        ),
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
    String question, {
    String? season,
    String? episode,
  }) async {
    final tracking = widget.tracking;
    if (tracking == null || _loading || widget.pending) return;
    await confirmShowBatch(
      context,
      showId: widget.show.id!,
      tracking: tracking,
      apply: widget.apply,
      scope: scope,
      question: question,
      season: season,
      episode: episode,
    );
  }

  Future<void> _episodeSheet(CatalogEpisode episode) async {
    final tracked = widget.tracking;
    if (tracked == null || widget.pending) return;
    final numbered = (_selected?.number ?? 0) > 0;
    final canMark = tracked.intent != null || numbered;
    final action = await showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'E${episode.number} · ${episode.title}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (episode.watched)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'Watched · ${episode.watchedOn == null ? 'date unknown' : readableDay(episode.watchedOn!)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (!episode.watched && canMark)
              ListTile(
                leading: const Icon(PhosphorIconsRegular.checkCircle),
                title: const Text('Mark watched'),
                onTap: () => Navigator.pop(context, 'mark'),
              ),
            if (numbered)
              ListTile(
                leading: const Icon(PhosphorIconsRegular.checks),
                title: Text('Mark watched up to E${episode.number}'),
                onTap: () => Navigator.pop(context, 'through'),
              ),
            if (episode.watched) ...[
              ListTile(
                leading: const Icon(PhosphorIconsRegular.calendarBlank),
                title: const Text('Edit watch date'),
                onTap: () => Navigator.pop(context, 'date'),
              ),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.calendarX),
                title: const Text('Clear date'),
                onTap: () => Navigator.pop(context, 'clear'),
              ),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.xCircle),
                title: const Text('Mark unwatched'),
                onTap: () => Navigator.pop(context, 'unwatch'),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'through') {
      await _batch(
        'mark_through',
        'Mark through episode ${episode.number}?',
        episode: episode.id,
      );
    } else {
      await _change(episode, action);
    }
  }

  Widget _episodeRow(
    CatalogEpisode episode,
    TrackingState? tracked,
    bool numbered,
  ) {
    final canToggle =
        tracked != null &&
        !widget.pending &&
        (episode.watched || tracked.intent != null || numbered);
    final action = episode.watched ? 'unwatch' : 'mark';
    final actionLabel = episode.watched ? 'Mark unwatched' : 'Mark watched';
    final day = DateTime.tryParse(episode.releaseDay ?? '');
    final next = tracked?.next?.id == episode.id;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              '${episode.number}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: mutedColor,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (next)
                  const Text(
                    'Next up',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: coralColor,
                    ),
                  ),
                Text(
                  episode.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (day != null)
                  Text(
                    readableDate(day),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (tracked != null)
            IconButton(
              tooltip: actionLabel,
              onPressed: canToggle ? () => _change(episode, action) : null,
              icon: Icon(
                episode.watched
                    ? PhosphorIconsFill.checkCircle
                    : PhosphorIconsRegular.circle,
                size: 26,
                color: episode.watched
                    ? mutedColor
                    : next
                    ? coralColor
                    : hairlineColor,
              ),
            ),
        ],
      ),
    );
    return Semantics(
      label: episode.watched ? 'Watched' : 'Not watched',
      customSemanticsActions: canToggle
          ? {
              CustomSemanticsAction(label: actionLabel): () =>
                  _change(episode, action),
            }
          : null,
      child: GestureDetector(
        onLongPress: tracked == null || widget.pending
            ? null
            : () => _episodeSheet(episode),
        child: Dismissible(
          key: ValueKey('swipe-${episode.id}'),
          direction: canToggle
              ? DismissDirection.startToEnd
              : DismissDirection.none,
          confirmDismiss: (_) async {
            _change(episode, action);
            return false;
          },
          child: row,
        ),
      ),
    );
  }

  String _seasonLabel(CatalogSeason season) =>
      season.number > 0 ? 'Season ${season.number}' : season.title;

  bool _done(CatalogSeason season) {
    final p = _progress[season.id];
    return p != null && p.released > 0 && p.watched >= p.released;
  }

  String? _progressText(CatalogSeason season) {
    final p = _progress[season.id];
    if (widget.tracking == null || p == null || p.released == 0) return null;
    return '${p.watched} / ${p.released}';
  }

  Widget _picker(CatalogSeason selected) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: _pickSeason,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: hairlineColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _seasonLabel(selected),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            '${_seasons.length} seasons',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(width: 8),
          const Icon(PhosphorIconsRegular.caretDown, size: 18),
        ],
      ),
    ),
  );

  Future<void> _pickSeason() async {
    final picked = await showModalBottomSheet<CatalogSeason>(
      useRootNavigator: true,
      isScrollControlled: true,
      context: context,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final season in _seasons)
                ListTile(
                  selected: season.id == _selected?.id,
                  title: Text(_seasonLabel(season)),
                  trailing: widget.tracking != null && _done(season)
                      ? const Icon(PhosphorIconsBold.check, size: 18)
                      : switch (_progressText(season)) {
                          final text? => Text(text),
                          null => null,
                        },
                  onTap: () => Navigator.pop(context, season),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted && picked.id != _selected?.id) {
      await _load(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selected;
    final tracked = widget.tracking;
    final released = _episodes.where((e) => e.released).toList();
    final upcoming = _episodes.where((e) => !e.released);
    final busy = _loading || widget.pending;
    final numbered = (selected?.number ?? 0) > 0;
    final batch = [
      if (numbered && tracked?.intent != null)
        (
          'mark_season_unwatched',
          'Mark season unwatched',
          'Mark this season unwatched?',
        ),
      if (tracked?.intent != null)
        ('remove_show', 'Remove show tracking', 'Remove show tracking?'),
    ];
    final seasonWatched = released.where((e) => e.watched).length;
    final canMarkAll =
        tracked != null &&
        ['Ended', 'Canceled'].contains(widget.show.releaseStatus) &&
        tracked.watched < tracked.released;
    final canMarkSeason =
        tracked != null &&
        numbered &&
        !_loading &&
        seasonWatched < released.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        SectionHeader(
          'Seasons',
          padding: EdgeInsets.zero,
          trailing: tracked == null || (batch.isEmpty && !canMarkAll)
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canMarkAll)
                      ActionLink(
                        icon: PhosphorIconsRegular.checks,
                        label: 'Mark all watched',
                        onTap: busy
                            ? null
                            : () => _batch(
                                'mark_ended_show_watched',
                                'Mark all released episodes watched?',
                              ),
                      ),
                    if (batch.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: 'Season actions',
                        enabled: !busy,
                        icon: const Icon(PhosphorIconsRegular.dotsThree),
                        onSelected: (scope) {
                          final (_, _, question) = batch.firstWhere(
                            (item) => item.$1 == scope,
                          );
                          _batch(
                            scope,
                            question,
                            season: scope.contains('season')
                                ? selected!.id
                                : null,
                          );
                        },
                        itemBuilder: (context) => [
                          for (final (scope, label, _) in batch)
                            PopupMenuItem(value: scope, child: Text(label)),
                        ],
                      ),
                  ],
                ),
        ),
        if (_seasons.length > 6 && selected != null)
          _picker(selected)
        else if (_seasons.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _seasons.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final season = _seasons[index];
                final done = tracked != null && _done(season);
                return ChoiceChip(
                  avatar: done
                      ? const Icon(PhosphorIconsBold.check, size: 14)
                      : null,
                  label: Text(_seasonLabel(season)),
                  tooltip: season.title,
                  selected: season.id == selected?.id,
                  onSelected: (_) => _load(season),
                );
              },
            ),
          ),
        if (tracked != null && !_loading && released.isNotEmpty) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: seasonWatched / released.length,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            semanticsLabel: 'Season episodes watched',
            semanticsValue: '$seasonWatched of ${released.length}',
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '$seasonWatched of ${released.length} watched',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (canMarkSeason)
                ActionLink(
                  icon: PhosphorIconsRegular.checks,
                  label: 'Mark season watched',
                  onTap: busy
                      ? null
                      : () => _batch(
                          'mark_season_watched',
                          'Mark released episodes watched?',
                          season: selected!.id,
                        ),
                ),
            ],
          ),
        ],
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Skeleton(rows: 4),
          ),
        if (_failed)
          InlineNotice(
            'Could not load episodes.',
            icon: PhosphorIconsRegular.warningCircle,
            action: 'Retry',
            onAction: selected == null ? _loadSeasons : () => _load(selected),
          ),
        if (!_loading && !_failed && _seasons.isEmpty)
          const InlineNotice('Season information is unavailable.'),
        if (selected != null && widget.show.id != null)
          OpinionActions(
            key: ValueKey(selected.id),
            title: widget.show.id!,
            season: selected.id,
            label: 'season',
          ),
        const SizedBox(height: 4),
        for (final episode in released) _episodeRow(episode, tracked, numbered),
        if (upcoming.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Upcoming', style: theme.textTheme.titleMedium),
          for (final episode in upcoming)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${episode.number}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: mutedColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      episode.title,
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  Text(
                    episode.releaseDay == null
                        ? 'Date unknown'
                        : readableDay(episode.releaseDay!),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
