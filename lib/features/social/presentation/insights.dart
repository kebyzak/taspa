import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../auth/auth_cubit.dart';
import '../../catalog/presentation/artwork.dart';
import '../data/social_repository.dart';

const _track = Color(0xff3a4350);
const _tabular = [ui.FontFeature.tabularFigures()];
const _months = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];
const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

typedef _Period = ({String label, String scope, DateTime? from, DateTime? to});

List<_Period> _periods(DateTime now) => [
  (
    label: 'Month',
    scope: 'this month',
    from: DateTime.utc(now.year, now.month),
    to: DateTime.utc(now.year, now.month + 1),
  ),
  (
    label: '${now.year}',
    scope: 'in ${now.year}',
    from: DateTime.utc(now.year),
    to: DateTime.utc(now.year + 1),
  ),
  (
    label: '${now.year - 1}',
    scope: 'in ${now.year - 1}',
    from: DateTime.utc(now.year - 1),
    to: DateTime.utc(now.year),
  ),
  (label: 'All time', scope: 'all time', from: null, to: null),
];

String _day(DateTime value) => value.toIso8601String().substring(0, 10);

String _hours(num minutes) => '${(minutes / 60).round()} h';

int _int(Object? value) => (value as num?)?.toInt() ?? 0;

class InsightsPage extends StatefulWidget {
  const InsightsPage({super.key, required this.id});

  final String id;

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  final _now = DateTime.now();
  late final _options = _periods(_now);
  int _selected = 1;
  late Future<SocialRow?> _data = _load();

  Future<SocialRow?> _load() {
    final period = _options[_selected];
    return context.read<SocialRepository>().one('profile_insights', {
      'owner_id': widget.id,
      'from_day': period.from == null ? null : _day(period.from!),
      'to_day': period.to == null ? null : _day(period.to!),
    });
  }

  void _select(int index) => setState(() {
    _selected = index;
    _data = _load();
  });

  @override
  Widget build(BuildContext context) {
    final period = _options[_selected];
    final own = context.watch<AccountCubit>().state.userId == widget.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Insights')),
      body: FutureBuilder<SocialRow?>(
        future: _data,
        builder: (context, result) {
          final chips = SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              children: [
                for (final (index, option) in _options.indexed)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(option.label),
                      selected: _selected == index,
                      onSelected: (_) => _select(index),
                    ),
                  ),
              ],
            ),
          );
          final Widget content;
          if (result.connectionState != ConnectionState.done) {
            content = const Padding(
              padding: EdgeInsets.only(top: 96),
              child: Center(child: CircularProgressIndicator()),
            );
          } else if (result.hasError) {
            content = EmptyState(
              icon: PhosphorIconsRegular.cloudSlash,
              title: 'Could not load insights',
              message: 'Check your connection and try again.',
              action: FilledButton(
                onPressed: () => _select(_selected),
                child: const Text('Try again'),
              ),
            );
          } else if (result.data == null) {
            content = const EmptyState(
              icon: PhosphorIconsRegular.lock,
              title: 'Insights are private',
              message: 'Follow to see what they watch.',
            );
          } else if (_int(result.data!['minutes']) == 0 &&
              _int(result.data!['movies']) + _int(result.data!['episodes']) ==
                  0) {
            content = EmptyState(
              icon: PhosphorIconsRegular.filmStrip,
              title: 'Nothing logged ${period.scope}',
              message: 'Mark movies and episodes watched to see insights here.',
            );
          } else {
            content = _Insights(
              data: _Stats(result.data!, period, _now),
              own: own,
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [chips, content],
          );
        },
      ),
    );
  }
}

class _Stats {
  _Stats(this.raw, this.period, this.now)
    : days = {
        for (final row in (raw['days'] as List).cast<SocialRow>())
          DateTime.parse('${row['day']}T00:00:00Z'): row,
      };

  final SocialRow raw;
  final _Period period;
  final DateTime now;
  final Map<DateTime, SocialRow> days;

  DateTime get today => DateTime.utc(now.year, now.month, now.day);

  DateTime get lastDay {
    final to = period.to;
    if (to == null) return today;
    final end = to.subtract(const Duration(days: 1));
    return end.isAfter(today) ? today : end;
  }

  List<(String, int, int)> timeline() {
    final from = period.from;
    final buckets = <(String, int, int)>[];
    void add(String label, bool Function(DateTime) inside) {
      var movies = 0, total = 0;
      for (final MapEntry(:key, :value) in days.entries) {
        if (!inside(key)) continue;
        movies += _int(value['movie_minutes']);
        total += _int(value['minutes']);
      }
      buckets.add((label, movies, total - movies));
    }

    if (from != null && period.to!.difference(from).inDays < 32) {
      final count = DateUtils.getDaysInMonth(from.year, from.month);
      for (var day = 1; day <= count; day++) {
        add(day == 1 || day % 5 == 0 ? '$day' : '', (d) => d.day == day);
      }
    } else if (from != null) {
      for (var month = 1; month <= 12; month++) {
        add(_months[month - 1], (d) => d.month == month);
      }
    } else {
      final years = days.keys.map((d) => d.year);
      final first = years.isEmpty
          ? now.year
          : math.max(years.reduce(math.min), now.year - 9);
      for (var year = first; year <= now.year; year++) {
        add("'${'$year'.substring(2)}", (d) => d.year == year);
      }
    }
    return buckets;
  }

  List<List<int?>> heatmap() {
    final end = lastDay;
    var start = end.subtract(const Duration(days: 26 * 7 - 1));
    if (period.from != null && start.isBefore(period.from!)) {
      start = period.from!;
    }
    start = start.subtract(Duration(days: start.weekday - 1));
    final weeks = <List<int?>>[];
    for (
      var day = start;
      !day.isAfter(end);
      day = day.add(const Duration(days: 7))
    ) {
      weeks.add([
        for (var offset = 0; offset < 7; offset++)
          () {
            final date = DateTime.utc(day.year, day.month, day.day + offset);
            if (date.isAfter(end) ||
                (period.from != null && date.isBefore(period.from!))) {
              return null;
            }
            final minutes = _int(days[date]?['minutes']);
            return minutes == 0
                ? 0
                : minutes < 60
                ? 1
                : minutes < 120
                ? 2
                : minutes < 240
                ? 3
                : 4;
          }(),
      ]);
    }
    return weeks;
  }

  List<int> weekdays() {
    final counts = List.filled(7, 0);
    for (final MapEntry(:key, :value) in days.entries) {
      counts[key.weekday - 1] +=
          _int(value['movies']) + _int(value['episodes']);
    }
    return counts;
  }

  ({int longest, DateTime? start, DateTime? end, int current}) streaks() {
    final sorted = days.keys.toList()..sort();
    var longest = 0, run = 0;
    DateTime? bestStart, bestEnd, runStart, previous;
    for (final day in sorted) {
      run = previous != null && day.difference(previous).inDays == 1
          ? run + 1
          : 1;
      if (run == 1) runStart = day;
      if (run > longest) {
        longest = run;
        bestStart = runStart;
        bestEnd = day;
      }
      previous = day;
    }
    final current = previous != null && today.difference(previous).inDays <= 1
        ? run
        : 0;
    return (longest: longest, start: bestStart, end: bestEnd, current: current);
  }

  ({int episodes, DateTime? day}) binge() {
    var best = 0;
    DateTime? when;
    for (final MapEntry(:key, :value) in days.entries) {
      final count = _int(value['episodes']);
      if (count > best) {
        best = count;
        when = key;
      }
    }
    return (episodes: best, day: when);
  }

  bool get coversToday =>
      (period.from == null || !today.isBefore(period.from!)) &&
      (period.to == null || today.isBefore(period.to!));
}

String _date(DateTime value) => '${_monthNames[value.month - 1]} ${value.day}';

class _Insights extends StatelessWidget {
  const _Insights({required this.data, required this.own});

  final _Stats data;
  final bool own;

  @override
  Widget build(BuildContext context) {
    final raw = data.raw;
    final minutes = _int(raw['minutes']);
    final previous = raw['previous_minutes'] as num?;
    final streak = data.streaks();
    final binge = data.binge();
    final ratings = raw['ratings'] as SocialRow;
    final average = ratings['average'] as num?;
    final delta = ratings['imdb_delta'] as num?;
    final weekdays = data.weekdays();
    final busiest = weekdays.indexOf(weekdays.reduce(math.max));
    final genres = (raw['genres'] as List).cast<SocialRow>();
    final decades = (raw['decades'] as List).cast<SocialRow>();
    final disagreements = (ratings['disagreements'] as List).cast<SocialRow>();
    final actors = (raw['actors'] as List).cast<SocialRow>();
    final creators = (raw['creators'] as List).cast<SocialRow>();
    final status = (raw['show_status'] as Map).cast<String, Object?>();
    final topShows = (raw['top_shows'] as List).cast<SocialRow>();
    final hasDays = data.days.isNotEmpty;

    String comparison() {
      if (previous == null) return '';
      final diff = ((minutes - previous) / 60).round();
      final against = data.period.label == 'Month'
          ? 'last month'
          : '${data.period.from!.year - 1}';
      if (diff == 0) return ' · same as $against';
      return ' · ${diff.abs()} h ${diff > 0 ? 'more' : 'less'} than $against';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Time watched ${data.period.scope}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  _hours(minutes),
                  style: const TextStyle(
                    fontFamily: 'Gloock',
                    fontSize: 64,
                    height: 1,
                    fontFeatures: _tabular,
                  ),
                ),
                Text(
                  '${(minutes / 1440).toStringAsFixed(1)} days of screen time${comparison()}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                _Split(
                  movies: _int(raw['movie_minutes']),
                  episodes: _int(raw['episode_minutes']),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _Legend(
                        color: coralColor,
                        label: 'Movies',
                        value: '${raw['movies']}',
                        detail: _hours(_int(raw['movie_minutes'])),
                      ),
                    ),
                    Expanded(
                      child: _Legend(
                        color: inkColor,
                        label: 'Episodes',
                        value: '${raw['episodes']}',
                        detail: _hours(_int(raw['episode_minutes'])),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _Grid(
            tiles: [
              (
                'Longest streak',
                '${streak.longest} ${streak.longest == 1 ? 'day' : 'days'}',
                streak.start == null
                    ? 'No dated logs'
                    : '${_date(streak.start!)} – ${_date(streak.end!)}',
              ),
              if (data.coversToday)
                (
                  'Current streak',
                  '${streak.current} ${streak.current == 1 ? 'day' : 'days'}',
                  streak.current > 0
                      ? 'Keep it going'
                      : 'Watch something today',
                )
              else
                ('Rewatches', '${raw['rewatches']}', 'movies seen again'),
              (
                'Biggest binge',
                '${binge.episodes} episodes',
                binge.day == null
                    ? 'in one day'
                    : 'in one day · ${_date(binge.day!)}',
              ),
              (
                'Average rating',
                average == null ? '–' : '$average',
                delta == null
                    ? '${ratings['count']} ratings'
                    : '${delta >= 0 ? '+' : '−'}${delta.abs()} vs IMDb',
              ),
            ],
          ),
          if (hasDays) ...[
            _Section(
              title: switch (data.period.label) {
                'Month' => 'By day',
                'All time' => 'By year',
                _ => 'By month',
              },
              trailing: 'hours',
              child: _StackedBars(data.timeline()),
            ),
            _Section(
              title: 'Watching days',
              trailing: '${data.days.length} active',
              child: _Heatmap(data.heatmap()),
            ),
            _Section(
              title: 'Your week',
              trailing: 'Busiest on ${_weekdayNames[busiest]}',
              child: _Columns(
                values: weekdays,
                labels: _weekdays,
                semantics:
                    'Titles watched by weekday, most on ${_weekdayNames[busiest]}',
              ),
            ),
          ],
          if (genres.isNotEmpty)
            _Section(
              title: 'Top genres',
              trailing: 'share of time',
              child: Column(
                children: [
                  for (final (index, genre) in genres.take(6).indexed)
                    _Meter(
                      label: genre['name'] as String,
                      value: _int(genre['minutes']),
                      max: _int(genres.first['minutes']),
                      detail:
                          '${_hours(_int(genre['minutes']))} · ${minutes == 0 ? 0 : (_int(genre['minutes']) * 100 / minutes).round()}%',
                      highlight: index == 0,
                    ),
                ],
              ),
            ),
          if (_int(ratings['count']) > 0)
            _Section(
              title: 'How you rate',
              trailing: '${ratings['count']} ratings',
              child: _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Columns(
                      values: (ratings['buckets'] as List).map(_int).toList(),
                      labels: [for (var i = 1; i <= 10; i++) '$i'],
                      semantics: 'Ratings from 1 to 10',
                      height: 110,
                    ),
                    if (delta != null) ...[
                      const Divider(height: 24),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: own ? 'You rate ' : 'They rate '),
                            TextSpan(
                              text: delta == 0
                                  ? 'the same as'
                                  : '${delta.abs()} ${delta > 0 ? 'higher' : 'lower'} than',
                              style: const TextStyle(
                                color: coralColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const TextSpan(text: ' IMDb on average.'),
                          ],
                        ),
                        style: const TextStyle(fontSize: 15, height: 1.47),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (disagreements.isNotEmpty)
            _Section(
              title: own ? 'You vs IMDb' : 'Them vs IMDb',
              trailing: 'biggest gaps',
              child: Column(
                children: [
                  for (final row in disagreements)
                    _TitleRow(
                      row: row,
                      subtitle: 'Rated ${row['score']} · IMDb ${row['imdb']}',
                      trailing: _Delta(row['delta'] as num),
                    ),
                ],
              ),
            ),
          if (decades.isNotEmpty)
            _Section(
              title: 'By decade',
              trailing: 'titles',
              child: _Columns(
                values: decades.map((d) => _int(d['titles'])).toList(),
                labels: [
                  for (final d in decades) "${'${d['decade']}'.substring(2)}s",
                ],
                semantics: 'Titles by release decade',
              ),
            ),
          if (actors.isNotEmpty || creators.isNotEmpty)
            _Section(
              title: 'Most watched people',
              child: _People(actors: actors, creators: creators),
            ),
          if (status.isNotEmpty)
            _Section(
              title: 'Shows',
              trailing: 'watched ${data.period.scope}',
              child: _Card(
                child: _ShowStatus(
                  status: status,
                  droppedAfter: raw['dropped_after'] as num?,
                ),
              ),
            ),
          if (topShows.isNotEmpty)
            _Section(
              title: 'Most time spent',
              trailing: 'shows',
              child: Column(
                children: [
                  for (final (index, row) in topShows.indexed)
                    _TitleRow(
                      row: row,
                      subtitle:
                          '${row['episodes']} episodes · ${_hours(_int(row['minutes']))}',
                      progress:
                          _int(row['minutes']) /
                          _int(topShows.first['minutes']),
                      highlight: index == 0,
                    ),
                ],
              ),
            ),
          if (own) _Recap(data: data, streak: streak.longest),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: surfaceColor,
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.trailing, required this.child});

  final String title;
  final String? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (trailing != null)
              Text(trailing!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

class _Split extends StatelessWidget {
  const _Split({required this.movies, required this.episodes});

  final int movies;
  final int episodes;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${_hours(movies)} movies, ${_hours(episodes)} episodes',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            if (movies > 0)
              Expanded(
                flex: movies,
                child: const ColoredBox(color: coralColor),
              ),
            if (movies > 0 && episodes > 0) const SizedBox(width: 2),
            if (episodes > 0)
              Expanded(
                flex: episodes,
                child: const ColoredBox(color: inkColor),
              ),
            if (movies + episodes == 0)
              const Expanded(child: ColoredBox(color: pressedColor)),
          ],
        ),
      ),
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    required this.value,
    required this.detail,
  });

  final Color color;
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          _Dot(color),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      Text.rich(
        TextSpan(
          children: [
            TextSpan(text: value),
            TextSpan(
              text: ' · $detail',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: mutedColor,
              ),
            ),
          ],
        ),
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFeatures: _tabular,
        ),
      ),
    ],
  );
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class _Grid extends StatelessWidget {
  const _Grid({required this.tiles});

  final List<(String, String, String)> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = (constraints.maxWidth - 8) / 2;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (label, value, note) in tiles)
            Container(
              width: width,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 24,
                      height: 28 / 24,
                      fontWeight: FontWeight.w600,
                      fontFeatures: _tabular,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    note,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

class _StackedBars extends StatelessWidget {
  const _StackedBars(this.buckets);

  final List<(String, int, int)> buckets;

  @override
  Widget build(BuildContext context) {
    final peak = buckets.map((b) => b.$2 + b.$3).fold(0, math.max);
    final peakIndex = buckets.indexWhere((b) => b.$2 + b.$3 == peak);
    final dense = buckets.length > 12;
    const height = 120.0;
    return Semantics(
      label: peak == 0
          ? 'No dated watch time'
          : 'Hours per period, peak ${_hours(peak)}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: height + 18,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (index, (_, movies, episodes)) in buckets.indexed)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: dense ? 1 : 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (!dense || index == peakIndex)
                            Text(
                              movies + episodes == 0
                                  ? ''
                                  : '${((movies + episodes) / 60).round()}',
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 11,
                                height: 14 / 11,
                                color: mutedColor,
                                fontFeatures: _tabular,
                              ),
                            ),
                          const SizedBox(height: 2),
                          ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(3),
                            ),
                            child: Column(
                              children: [
                                Container(
                                  height: peak == 0
                                      ? 0
                                      : height * episodes / peak,
                                  color: inkColor,
                                ),
                                Container(
                                  height: peak == 0
                                      ? 0
                                      : height * movies / peak,
                                  color: coralColor,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (label, _, _) in buckets)
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: const TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const Row(
            children: [
              _Dot(coralColor),
              SizedBox(width: 6),
              Text('Movies', style: TextStyle(fontSize: 13, color: mutedColor)),
              SizedBox(width: 16),
              _Dot(inkColor),
              SizedBox(width: 6),
              Text(
                'Episodes',
                style: TextStyle(fontSize: 13, color: mutedColor),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

const _heat = [
  Color(0xff1f2630),
  Color(0xff1f3a4a),
  Color(0xff2f6280),
  Color(0xff5296bc),
  coralColor,
];

class _Heatmap extends StatelessWidget {
  const _Heatmap(this.weeks);

  final List<List<int?>> weeks;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Calendar of days with something watched',
    excludeSemantics: true,
    child: LayoutBuilder(
      builder: (context, constraints) {
        const gap = 2.0;
        final cell = math.min(
          14.0,
          (constraints.maxWidth - gap * (weeks.length - 1)) / weeks.length,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (final (index, week) in weeks.indexed)
                  Padding(
                    padding: EdgeInsets.only(left: index == 0 ? 0 : gap),
                    child: Column(
                      children: [
                        for (final (day, level) in week.indexed)
                          Container(
                            width: cell,
                            height: cell,
                            margin: EdgeInsets.only(top: day == 0 ? 0 : gap),
                            decoration: BoxDecoration(
                              color: level == null ? null : _heat[level],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Text(
                  'Less ',
                  style: TextStyle(fontSize: 13, color: mutedColor),
                ),
                for (final color in _heat)
                  Container(
                    width: 11,
                    height: 11,
                    margin: const EdgeInsets.only(left: 3),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                const Text(
                  '  More',
                  style: TextStyle(fontSize: 13, color: mutedColor),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

class _Columns extends StatelessWidget {
  const _Columns({
    required this.values,
    required this.labels,
    required this.semantics,
    this.height = 96,
  });

  final List<int> values;
  final List<String> labels;
  final String semantics;
  final double height;

  @override
  Widget build(BuildContext context) {
    final peak = values.fold(0, math.max);
    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: height + 18,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final value in values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '$value',
                            style: const TextStyle(
                              fontSize: 11,
                              color: mutedColor,
                              fontFeatures: _tabular,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: peak == 0
                                ? 2
                                : math.max(2, height * value / peak - 4),
                            decoration: BoxDecoration(
                              color: value == peak && peak > 0
                                  ? coralColor
                                  : _track,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (index, label) in labels.indexed)
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: values[index] == peak && peak > 0
                          ? inkColor
                          : mutedColor,
                      fontWeight: values[index] == peak && peak > 0
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({
    required this.label,
    required this.value,
    required this.max,
    required this.detail,
    required this.highlight,
  });

  final String label;
  final int value;
  final int max;
  final String detail;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              detail,
              style: const TextStyle(
                fontSize: 15,
                color: mutedColor,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: max == 0 ? 0 : value / max,
            minHeight: 8,
            backgroundColor: pressedColor,
            color: highlight ? coralColor : mutedColor,
          ),
        ),
      ],
    ),
  );
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({
    required this.row,
    required this.subtitle,
    this.trailing,
    this.progress,
    this.highlight = false,
  });

  final SocialRow row;
  final String subtitle;
  final Widget? trailing;
  final double? progress;
  final bool highlight;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => context.push('/shared-title/${row['id']}'),
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 60,
            child: Artwork(row['poster_path'] as String?, radius: 6),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  row['display_title'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (progress != null) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: pressedColor,
                      color: highlight ? coralColor : mutedColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    ),
  );
}

class _Delta extends StatelessWidget {
  const _Delta(this.value);

  final num value;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 52),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: value > 0 ? selectedColor : pressedColor,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      '${value > 0 ? '+' : '−'}${value.abs()}',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: value > 0 ? const Color(0xffb5def2) : inkColor,
        fontFeatures: _tabular,
      ),
    ),
  );
}

class _People extends StatefulWidget {
  const _People({required this.actors, required this.creators});

  final List<SocialRow> actors;
  final List<SocialRow> creators;

  @override
  State<_People> createState() => _PeopleState();
}

class _PeopleState extends State<_People> {
  late bool _actors = widget.actors.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final people = _actors ? widget.actors : widget.creators;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (widget.actors.isNotEmpty)
              ChoiceChip(
                label: const Text('Actors'),
                selected: _actors,
                onSelected: (_) => setState(() => _actors = true),
              ),
            const SizedBox(width: 8),
            if (widget.creators.isNotEmpty)
              ChoiceChip(
                label: const Text('Directors'),
                selected: !_actors,
                onSelected: (_) => setState(() => _actors = false),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: people.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              final person = people[index];
              final name = person['name'] as String;
              return InkWell(
                onTap: () => context.push('/credits/${person['tmdb_id']}'),
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 76,
                  child: Column(
                    children: [
                      SizedBox(
                        width: 72,
                        height: 72,
                        child: Artwork(
                          person['portrait'] as String?,
                          radius: 36,
                          icon: PhosphorIconsRegular.user,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${person['titles']} titles',
                        style: const TextStyle(fontSize: 12, color: mutedColor),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ShowStatus extends StatelessWidget {
  const _ShowStatus({required this.status, required this.droppedAfter});

  final Map<String, Object?> status;
  final num? droppedAfter;

  static const _segments = [
    ('completed', 'Completed', coralColor),
    ('watching', 'Watching', inkColor),
    ('on_hold', 'On hold', Color(0xff7f8895)),
    ('dropped', 'Dropped', _track),
  ];

  @override
  Widget build(BuildContext context) {
    final counts = [for (final (key, _, _) in _segments) _int(status[key])];
    final total = counts.fold(0, (a, b) => a + b);
    final completed = counts.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Semantics(
              label:
                  '$total shows: ${[for (final (i, s) in _segments.indexed) '${counts[i]} ${s.$2.toLowerCase()}'].join(', ')}',
              excludeSemantics: true,
              child: SizedBox(
                width: 132,
                height: 132,
                child: CustomPaint(
                  painter: _Donut([
                    for (final (i, s) in _segments.indexed) (counts[i], s.$3),
                  ]),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$total',
                          style: const TextStyle(
                            fontFamily: 'Gloock',
                            fontSize: 40,
                            height: 1,
                          ),
                        ),
                        const Text(
                          'shows',
                          style: TextStyle(fontSize: 13, color: mutedColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                children: [
                  for (final (i, (_, label, color)) in _segments.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          _Dot(color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              label,
                              style: const TextStyle(fontSize: 15),
                            ),
                          ),
                          Text(
                            '${counts[i]}',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              fontFeatures: _tabular,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const Divider(height: 28),
        Text(
          [
            if (total > 0) '${(completed * 100 / total).round()}% finished',
            if (droppedAfter != null)
              'dropped after $droppedAfter episodes on average',
          ].join(' · '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Donut extends CustomPainter {
  _Donut(this.segments);

  final List<(int, Color)> segments;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = pressedColor);
    final total = segments.fold(0, (sum, s) => sum + s.$1);
    if (total == 0) return;
    const gap = 0.04;
    var start = -math.pi / 2;
    for (final (count, color) in segments) {
      if (count == 0) continue;
      final sweep = math.pi * 2 * count / total;
      canvas.drawArc(
        rect,
        start + gap / 2,
        math.max(0.01, sweep - gap),
        false,
        paint..color = color,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_Donut old) => old.segments != segments;
}

class _Recap extends StatefulWidget {
  const _Recap({required this.data, required this.streak});

  final _Stats data;
  final int streak;

  @override
  State<_Recap> createState() => _RecapState();
}

class _RecapState extends State<_Recap> {
  final _card = GlobalKey();
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final boundary =
          _card.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(png!.buffer.asUint8List(), mimeType: 'image/png'),
          ],
          fileNameOverrides: ['taspa-recap.png'],
        ),
      );
    } on Object catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not share. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.data.raw;
    final period = widget.data.period;
    final genres = raw['genres'] as List;
    final average = (raw['ratings'] as SocialRow)['average'];
    final posters = (raw['top_titles'] as List).cast<SocialRow>();
    final card = Container(
      width: 360,
      height: 640,
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 36),
      color: surfaceColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Taspa · ${period.label == 'Month' ? '${_monthNames[period.from!.month - 1]} ${period.from!.year}' : period.label}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: coralColor,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '${(_int(raw['minutes']) / 60).round()} hours',
            style: const TextStyle(
              fontFamily: 'Gloock',
              fontSize: 72,
              height: 1,
              color: inkColor,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '${raw['movies']} movies, ${raw['episodes']} episodes, ${widget.streak}-day streak',
            style: const TextStyle(
              fontSize: 20,
              height: 1.4,
              color: mutedColor,
            ),
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              for (final (index, row) in posters.indexed)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: index == 0 ? 0 : 8),
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: Artwork(row['poster_path'] as String?, radius: 8),
                    ),
                  ),
                ),
              for (var i = posters.length; i < 3; i++) const Spacer(),
            ],
          ),
          const Spacer(),
          if (genres.isNotEmpty)
            _RecapLine(
              'Top genre',
              (genres.first as SocialRow)['name'] as String,
            ),
          if (average != null) _RecapLine('Average rating', '$average'),
        ],
      ),
    );
    return _Section(
      title: 'Your recap',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 240,
              decoration: BoxDecoration(
                border: Border.all(color: hairlineColor),
                borderRadius: BorderRadius.circular(20),
              ),
              clipBehavior: Clip.antiAlias,
              child: FittedBox(
                child: RepaintBoundary(key: _card, child: card),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _share,
            icon: const Icon(PhosphorIconsRegular.export),
            label: Text(_busy ? 'Preparing…' : 'Share recap'),
          ),
        ],
      ),
    );
  }
}

class _RecapLine extends StatelessWidget {
  const _RecapLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label  ',
            style: const TextStyle(color: mutedColor),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(color: inkColor),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 18),
    ),
  );
}
