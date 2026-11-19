import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../../core/backend_config.dart';
import '../../auth/auth_cubit.dart';
import '../../catalog/data/catalog_repository.dart';
import '../../catalog/presentation/artwork.dart';
import '../../library/data/library_repository.dart';
import '../data/social_repository.dart';
import 'reviews.dart';

class PeopleSearchPage extends StatefulWidget {
  const PeopleSearchPage({super.key});

  @override
  State<PeopleSearchPage> createState() => _PeopleSearchPageState();
}

class _PeopleSearchPageState extends State<PeopleSearchPage> {
  Timer? _debounce;
  Future<List<SocialRow>>? _results;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Find people')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Search handles',
            prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass),
          ),
          onChanged: (text) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () {
              if (mounted) {
                setState(() {
                  _results = context.read<SocialRepository>().findPeople(text);
                });
              }
            });
          },
        ),
        FutureBuilder(
          future: _results,
          builder: (context, result) {
            if (result.connectionState == ConnectionState.waiting) {
              return const LinearProgressIndicator();
            }
            if (result.hasError) {
              return const Text('Search is temporarily unavailable.');
            }
            final rows = result.data;
            if (rows == null) return const SizedBox.shrink();
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('No matching profiles.'),
              );
            }
            return Column(children: [for (final row in rows) _PersonTile(row)]);
          },
        ),
      ],
    ),
  );
}

class _PersonTile extends StatelessWidget {
  const _PersonTile(this.row, {this.action});

  final SocialRow row;
  final Widget? action;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Avatar(row['handle'] as String, size: 40),
    title: Text(row['display_name'] as String? ?? '@${row['handle']}'),
    subtitle: row['display_name'] == null ? null : Text('@${row['handle']}'),
    trailing: action,
    onTap: () => context.push('/people/${row['user_id']}'),
  );
}

class FollowingPage extends StatefulWidget {
  const FollowingPage({super.key});

  @override
  State<FollowingPage> createState() => _FollowingPageState();
}

class _FollowingPageState extends State<FollowingPage> {
  List<SocialRow> _rows = [];
  final _expanded = <String>{};
  bool _working = false, _failed = false, _more = false, _loaded = false;

  /// Groups newest-first rows by local day; one person's episodes of one show on a day become a single item
  /// whose 'episodes' holds every row of the bundle.
  static List<({String label, List<SocialRow> items})> _days(
    List<SocialRow> rows,
  ) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = <String, List<SocialRow>>{};
    final bundles = <String, SocialRow>{};
    for (final row in rows) {
      final at = DateTime.tryParse(row['created_at'] as String? ?? '')
          ?.toLocal();
      if (at == null) continue;
      final day = DateTime(at.year, at.month, at.day);
      final gap = today.difference(day).inDays;
      final label = switch (gap) {
        0 => 'Today',
        1 => 'Yesterday',
        _ =>
          '${_weekdays[day.weekday - 1]}, ${day.day} ${_months[day.month - 1]}${day.year == now.year ? '' : ' ${day.year}'}',
      };
      final items = days.putIfAbsent(label, () => []);
      if (row['kind'] == 'episode') {
        final key = '$label|${row['actor_id']}|${row['title_id']}';
        if (bundles[key] case final bundle?) {
          (bundle['episodes'] as List<SocialRow>).add(row);
          continue;
        }
        items.add(
          bundles[key] = {
            ...row,
            'episodes': <SocialRow>[row],
          },
        );
      } else {
        items.add(row);
      }
    }
    return [
      for (final MapEntry(:key, :value) in days.entries)
        (label: key, items: value),
    ];
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
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

  // Own watches are part of the feed, so tracking changes refresh it.
  late final _changes = [
    context.read<LibraryRepository>().changes.listen((_) => _load()),
    context.read<SocialRepository>().changes.listen((_) => _load()),
  ];

  @override
  void initState() {
    super.initState();
    _changes;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final sub in _changes) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    if (!mounted ||
        _working ||
        context.read<AccountCubit>().state.phase != AccountPhase.ready) {
      return;
    }
    final owner = context.read<AccountCubit>().state.userId;
    setState(() {
      _working = true;
      _failed = false;
    });
    try {
      final rows = await context.read<SocialRepository>().feed(
        after: append ? _rows.lastOrNull : null,
      );
      if (!mounted || owner != context.read<AccountCubit>().state.userId) {
        return;
      }
      setState(() {
        _loaded = true;
        _rows = append ? [..._rows, ...rows] : rows;
        _more = rows.length == 20;
      });
    } on Exception {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready =
        context.watch<AccountCubit>().state.phase == AccountPhase.ready;
    return BlocListener<AccountCubit, Account>(
      listener: (context, user) {
        if (user.phase == AccountPhase.ready) {
          _load();
        } else {
          setState(() {
            _rows = [];
            _loaded = false;
            _more = false;
          });
        }
      },
      child: !ready
          ? EmptyState(
              icon: PhosphorIconsRegular.users,
              title: 'See what friends watch',
              message:
                  'Sign in to follow people and see their ratings and reviews.',
              action: FilledButton(
                onPressed: () => context.push('/account'),
                child: const Text('Sign in'),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  if (_working)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: LinearProgressIndicator(),
                    ),
                  if (_failed)
                    InlineNotice(
                      'Could not load Following.',
                      icon: PhosphorIconsRegular.warningCircle,
                      action: 'Retry',
                      onAction: _load,
                    ),
                  if (_loaded && _rows.isEmpty)
                    EmptyState(
                      icon: PhosphorIconsRegular.users,
                      title: 'Your feed is quiet',
                      message: 'What you and the people you follow watch shows up here. Mark something watched or find friends.',
                      action: FilledButton.icon(
                        onPressed: () => context.push('/people'),
                        icon: const Icon(
                          PhosphorIconsRegular.userPlus,
                          size: 20,
                        ),
                        label: const Text('Find people'),
                      ),
                    ),
                  for (final day in _days(_rows)) ...[
                    SectionHeader(
                      day.label,
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                    ),
                    for (final item
                        in _expanded.contains(day.label)
                            ? day.items
                            : day.items.take(4))
                      _FeedEntry(item),
                    if (day.items.length > 4 && !_expanded.contains(day.label))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () =>
                              setState(() => _expanded.add(day.label)),
                          child: Text('Show all ${day.items.length}'),
                        ),
                      ),
                  ],
                  if (_more && !_working)
                    TextButton(
                      onPressed: () => _load(append: true),
                      child: const Text('Load more'),
                    ),
                ],
              ),
            ),
    );
  }
}

/// One Feed item: who did what and when, then the title card (or the review card).
class _FeedEntry extends StatelessWidget {
  const _FeedEntry(this.row);

  final SocialRow row;

  static String _ago(String? value) {
    final at = DateTime.tryParse(value ?? '');
    if (at == null) return '';
    final gap = DateTime.now().difference(at.toLocal());
    if (gap.inMinutes < 1) return 'now';
    if (gap.inHours < 1) return '${gap.inMinutes}m';
    if (gap.inDays < 1) return '${gap.inHours}h';
    if (gap.inDays < 7) return '${gap.inDays}d';
    return '${at.day}.${at.month.toString().padLeft(2, '0')}.${at.year % 100}';
  }

  @override
  Widget build(BuildContext context) {
    final own = row['own'] == true;
    final episodes = [...?(row['episodes'] as List<SocialRow>?)]
      ..sort(
        (a, b) =>
            ((a['season_number'] as int) * 10000 + (a['episode_number'] as int))
                .compareTo(
                  (b['season_number'] as int) * 10000 +
                      (b['episode_number'] as int),
                ),
      );
    String code(SocialRow e) =>
        'S${e['season_number']} E${e['episode_number']}';
    final verb = switch (row['kind']) {
      _ when row['review'] != null => 'reviewed',
      'rating' => 'rated',
      'first_show' => 'started watching',
      'wanted' => 'wants to watch',
      'import' => 'imported ${row['count']} titles from ${row['source']}',
      'episode' when episodes.length > 1 =>
        'watched ${episodes.length} episodes',
      'episode' => 'watched an episode',
      _ => 'watched',
    };
    final detail = switch (episodes) {
      [] => null,
      [final e] => '${code(e)} · ${e['episode']}',
      [final first, ..., final last] => '${code(first)} – ${code(last)}',
    };
    final title =
        '${row['title']}${row['season'] == null ? '' : ' · ${row['season']}'}';
    final open = '/titles/${row['media']}/${row['tmdb_id']}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => context.push('/people/${row['actor_id']}'),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Avatar(row['handle'] as String, size: 32),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: own ? 'You' : '@${row['handle']}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(
                            text: ' $verb',
                            style: const TextStyle(color: mutedColor),
                          ),
                        ],
                      ),
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  Text(
                    _ago(row['created_at'] as String?),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          if (row['review'] case final SocialRow review)
            ReviewTile(review, showTitle: true)
          else if (row['kind'] != 'import')
            Card(
              child: InkWell(
                onTap: () => context.push(open),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        height: 72,
                        child: Artwork(row['poster'] as String?),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              detail ??
                                  [
                                    row['media'] == 'show'
                                        ? 'TV show'
                                        : 'Movie',
                                    if (row['watched_on'] case final String day)
                                      day,
                                  ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      // Ratings and watched logs both carry the actor's score when they rated it.
                      if (row['score'] case final num score) ...[
                        StarScore(score),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PersonPage extends StatefulWidget {
  const PersonPage({super.key, required this.id, this.inTab = false});

  final String id;
  final bool inTab;

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  late Future<SocialRow?> _profile = _fetch();
  int _avatarVersion = 0;
  int _generation = 0;
  bool _regionSent = false;
  final _lists = GlobalKey<_ProfileListsState>();

  // Counts and lists change when anything is logged, rated or followed anywhere in the app.
  late final _changes = [
    context.read<LibraryRepository>().changes.listen((_) => _reload()),
    context.read<SocialRepository>().changes.listen((_) => _reload()),
  ];

  void _reload() {
    if (mounted) {
      setState(() {
        _profile = _fetch();
        _generation++;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _changes;
  }

  @override
  void dispose() {
    for (final sub in _changes) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Future<SocialRow?> _fetch() async {
    final repo = context.read<SocialRepository>();
    final row = await repo.one('profile_page', {'target': widget.id});
    // Own profile carries market/timezone: keep them in step with the phone so release reminders just work.
    if (row != null && row.containsKey('timezone') && !_regionSent) {
      final region = _deviceRegion();
      if (region.entries.any((field) => row[field.key] != field.value)) {
        _regionSent = true; // Once per page: the write fires a change that refetches this profile.
        unawaited(
          repo
              .change('profile_update', {'fields': region})
              .then((_) {}, onError: (Object _) {}),
        );
      }
    }
    return row;
  }

  static SocialRow _deviceRegion() {
    final country = ui.PlatformDispatcher.instance.locale.countryCode
        ?.toUpperCase();
    final offset = DateTime.now().timeZoneOffset;
    final hours = offset.inHours;
    return {
      if (country != null && RegExp(r'^[A-Z]{2}$').hasMatch(country))
        'market': country,
      // shortcut: fixed-offset Etc zone (no DST, skips half-hour zones); add a native IANA lookup for DST markets.
      if (offset.inMinutes % 60 == 0)
        'timezone': hours == 0
            ? 'Etc/UTC'
            : 'Etc/GMT${hours > 0 ? '-' : '+'}${hours.abs()}',
    };
  }

  Future<void> _change(String rpc, SocialRow params) async {
    try {
      await context.read<SocialRepository>().change(
        rpc,
        params,
      ); // The change stream reloads this page.
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save. Try again.')),
        );
      }
    }
  }

  Future<void> _edit(SocialRow row) async {
    final update = await showModalBottomSheet<SocialRow>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (context) => _ProfileEditor(row),
    );
    if (update != null && mounted) {
      await _change('profile_update', {'fields': update});
    }
  }

  Future<void> _changeAvatar(bool remove) async {
    final repository = context.read<SocialRepository>();
    try {
      if (remove) {
        await repository.changeAvatar(null);
      } else {
        final file = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 384,
          maxHeight: 384,
          requestFullMetadata: false,
        );
        if (file == null) return;
        if (await file.length() > 8 * 1024 * 1024) {
          throw const FormatException('Image too large');
        }
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        try {
          final frame = await codec.getNextFrame();
          try {
            if (frame.image.width > 512 || frame.image.height > 512) {
              throw const FormatException('Image too large');
            }
            final data = await frame.image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (data == null || data.lengthInBytes > 1024 * 1024) {
              throw const FormatException('Image too large');
            }
            await repository.changeAvatar(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }
      if (mounted) setState(() => _avatarVersion++);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update your profile photo.')),
        );
      }
    }
  }

  Future<void> _photoSheet() async {
    final remove = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(PhosphorIconsRegular.image),
              title: const Text('Choose photo'),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(PhosphorIconsRegular.trash),
              title: const Text('Remove photo'),
              onTap: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (remove != null && mounted) await _changeAvatar(remove);
  }

  Future<void> _settingsSheet() async {
    final route = await showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (icon, label, value) in [
              (PhosphorIconsRegular.userCircle, 'Profile photo', 'photo'),
              (
                PhosphorIconsRegular.userPlus,
                'Follow requests',
                '/people/${widget.id}/requests',
              ),
              (
                PhosphorIconsRegular.downloadSimple,
                'Import from Must',
                '/import-must',
              ),
              (PhosphorIconsRegular.export, 'Export library', 'export'),
              (
                PhosphorIconsRegular.bell,
                'Notification settings',
                '/notification-settings',
              ),
              (PhosphorIconsRegular.userGear, 'Account', '/account'),
              (PhosphorIconsRegular.info, 'About Taspa', '/help'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (route == null || !mounted) return;
    if (route == 'photo') {
      await _photoSheet();
    } else if (route == 'export') {
      await _export();
    } else {
      await context.push(route);
    }
  }

  /// Everything the owner logged as JSON, saved where they pick in the system save dialog (Downloads by default).
  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final library = await context.read<SocialRepository>().one(
        'export_library',
      );
      final saved = await FilePicker.saveFile(
        fileName: 'taspa-library.json',
        bytes: utf8.encode(const JsonEncoder.withIndent('  ').convert(library)),
        mimeType: 'application/json',
      );
      if (saved != null) {
        messenger.showSnackBar(const SnackBar(content: Text('Library saved.')));
      }
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not export your library. Try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = FutureBuilder(
      future: _profile,
      builder: (context, result) {
        if (result.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() {
                _profile = _fetch();
              }),
              child: const Text('Could not load profile. Retry'),
            ),
          );
        }
        if (result.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final row = result.data;
        if (row == null) {
          return const Center(child: Text('This profile is unavailable.'));
        }
        final own = row['own'] == true;
        final ready =
            context.watch<AccountCubit>().state.phase == AccountPhase.ready;
        final relationship = row['relationship'];
        final handle = row['handle'] as String;
        final name = row['display_name'] as String?;
        final library = row['can_read_library'] == true;
        final initials = Center(
          child: Text(
            handle[0].toUpperCase(),
            style: const TextStyle(
              fontFamily: 'Instrument Serif',
              fontSize: 32,
              color: coralColor,
            ),
          ),
        );
        final followLabel = switch (relationship) {
          'accepted' => 'Following',
          'pending' => 'Requested',
          _ => row['private'] == true ? 'Request to follow' : 'Follow',
        };
        void follow() => ready
            ? _change('set_follow', {
                'target': widget.id,
                'follow': relationship == null,
              })
            : context.push('/account');
        final stats = [
          if (library) ...[
            ('${row['want'] ?? 0}', 'Want', 'wanted'),
            ('${row['movies'] ?? 0}', 'Watched', 'watched_movies'),
            (
              '${row['series'] ?? row['shows'] ?? 0}',
              'Series',
              'watched_shows',
            ),
            ('${row['episodes'] ?? 0}', 'Episodes', 'watched_shows'),
          ],
        ];
        final header = Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Semantics(
                    button: own,
                    label: own ? 'Change profile photo' : null,
                    child: GestureDetector(
                      onTap: own ? () => _photoSheet() : null,
                      child: Container(
                        width: 80,
                        height: 80,
                        clipBehavior: Clip.antiAlias,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: selectedColor,
                        ),
                        child: row['can_read'] == true
                            ? Image.network(
                                '$backendUrl/functions/v1/avatar?user=${widget.id}&v=$_avatarVersion',
                                headers: context
                                    .read<SocialRepository>()
                                    .avatarHeaders,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => initials,
                              )
                            : initials,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name ?? handle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Instrument Serif',
                            fontSize: 28,
                            height: 1.1,
                            color: inkColor,
                          ),
                        ),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '@$handle',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: mutedColor,
                                ),
                              ),
                            ),
                            if (row['private'] == true) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                PhosphorIconsRegular.lock,
                                size: 14,
                                color: mutedColor,
                                semanticLabel: 'Private profile',
                              ),
                            ],
                          ],
                        ),
                        if (row['can_read'] == true) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 12,
                            children: [
                              for (final (count, label, list) in [
                                (row['followers'], 'followers', 'followers'),
                                (row['following'], 'following', 'following'),
                              ])
                                InkWell(
                                  onTap: () => context.push(
                                    '/people/${widget.id}/$list',
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: '$count',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: inkColor,
                                            ),
                                          ),
                                          TextSpan(text: ' $label'),
                                        ],
                                      ),
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: mutedColor,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (row['bio'] case final String bio when bio.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(bio, style: const TextStyle(fontSize: 15)),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: own
                        ? OutlinedButton(
                            onPressed: () => _edit(row),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 44),
                            ),
                            child: const Text('Edit profile'),
                          )
                        : relationship == null
                        ? FilledButton(
                            onPressed: follow,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(48, 44),
                            ),
                            child: Text(followLabel),
                          )
                        : OutlinedButton(
                            onPressed: follow,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 44),
                            ),
                            child: Text(followLabel),
                          ),
                  ),
                  if (own || ready) ...[
                    const SizedBox(width: 8),
                    own
                        ? IconButton.outlined(
                            tooltip: 'Settings',
                            onPressed: _settingsSheet,
                            style: IconButton.styleFrom(
                              side: const BorderSide(color: hairlineColor),
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(12),
                                ),
                              ),
                              minimumSize: const Size(48, 44),
                            ),
                            icon: const Icon(PhosphorIconsRegular.gear),
                          )
                        : PopupMenuButton<String>(
                            tooltip: 'More actions',
                            icon: const Icon(PhosphorIconsRegular.dotsThree),
                            onSelected: (choice) => choice == 'report'
                                ? reportSocial(context, widget.id, 'profile')
                                : _change('set_block', {
                                    'target': widget.id,
                                    'blocked': true,
                                  }),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'report',
                                child: Text('Report'),
                              ),
                              PopupMenuItem(
                                value: 'block',
                                child: Text('Block'),
                              ),
                            ],
                            child: Container(
                              width: 48,
                              height: 44,
                              decoration: BoxDecoration(
                                border: Border.all(color: hairlineColor),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(PhosphorIconsRegular.dotsThree),
                            ),
                          ),
                  ],
                ],
              ),
              if (stats.isNotEmpty) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    for (final (value, label, section) in stats)
                      Expanded(
                        child: InkWell(
                          onTap: () => _lists.currentState?.select(section),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              children: [
                                Text(
                                  value,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: [
                                      ui.FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                Text(
                                  label,
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  softWrap: false,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(),
              ],
              const SizedBox(height: 12),
            ],
          ),
        );
        return RefreshIndicator(
          onRefresh: () async {
            setState(() {
              _profile = _fetch();
              _generation++;
            });
            await _profile;
          },
          child: NotificationListener<ScrollNotification>(
            // Load the next page of the open list when the user nears the bottom.
            onNotification: (note) {
              if (note.metrics.extentAfter < 600) _lists.currentState?.more();
              return false;
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: header),
                if (library || row['can_read'] == true)
                  _ProfileLists(
                    key: _lists,
                    owner: widget.id,
                    library: library,
                    reviews: row['can_read'] == true,
                    generation: _generation,
                  )
                else
                  const SliverToBoxAdapter(
                    child: EmptyState(
                      icon: PhosphorIconsRegular.lock,
                      title: 'This profile is private',
                      message: 'Follow to see what they watch.',
                    ),
                  ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
              ],
            ),
          ),
        );
      },
    );
    return widget.inTab
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('Profile')),
            body: body,
          );
  }
}

/// Must-style lists under the profile header: chips, then a poster grid that keeps loading as you scroll.
class _ProfileLists extends StatefulWidget {
  const _ProfileLists({
    super.key,
    required this.owner,
    required this.library,
    required this.reviews,
    required this.generation,
  });

  final String owner;
  final bool library;
  final bool reviews;
  final int generation;

  @override
  State<_ProfileLists> createState() => _ProfileListsState();
}

class _ProfileListsState extends State<_ProfileLists> {
  late String _section = widget.library ? 'wanted' : 'reviews';
  String _sort = 'activity';
  bool _ascending = false;
  List<SocialRow> _rows = [];
  bool _working = false, _failed = false, _end = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ProfileLists old) {
    super.didUpdateWidget(old);
    if (old.generation != widget.generation) _load();
  }

  void select(String section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _sort = _LibrarySortBar.fit(_sort, section);
    });
    _load();
  }

  void more() {
    if (!_working && !_end && !_failed && _rows.isNotEmpty) _load(more: true);
  }

  Future<void> _load({bool more = false}) async {
    final request = ++_request;
    final section = _section;
    setState(() {
      _working = true;
      _failed = false;
      if (!more) {
        _rows = [];
        _end = false;
      }
    });
    try {
      final repo = context.read<SocialRepository>();
      final last = more ? _rows.lastOrNull : null;
      final rows = section == 'reviews'
          ? await repo.reviews(author: widget.owner, after: last)
          : await repo.many('profile_library', {
              'owner_id': widget.owner,
              'section': section,
              'sort': _sort,
              'ascending': _ascending,
              'before_value': ?last?['sort_value'],
              'before_title': ?last?['title']?['id'],
            });
      if (!mounted || request != _request) return;
      setState(() {
        _rows = [..._rows, ...rows];
        _end = rows.length < 20;
      });
    } on Exception {
      if (mounted && request == _request) setState(() => _failed = true);
    } finally {
      if (mounted && request == _request) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reviews = _section == 'reviews';
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final (value, label) in [
                  if (widget.library) ...const [
                    ('wanted', 'Want'),
                    ('watched_movies', 'Watched'),
                    ('watched_shows', 'Series'),
                  ],
                  if (widget.reviews) ('reviews', 'Reviews'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _section == value,
                      onSelected: (_) => select(value),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (reviews)
          const SliverToBoxAdapter(child: SizedBox(height: 16))
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: _LibrarySortBar(
                owner: widget.owner,
                section: _section,
                sort: _sort,
                ascending: _ascending,
                onChanged: (sort, ascending) {
                  setState(() {
                    _sort = sort;
                    _ascending = ascending;
                  });
                  _load();
                },
              ),
            ),
          ),
        if (reviews)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: _rows.length,
              itemBuilder: (context, index) =>
                  ReviewTile(_rows[index], showTitle: true),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
                childAspectRatio: .5,
              ),
              itemCount: _rows.length,
              itemBuilder: (context, index) {
                final content = _rows[index]['title'] as SocialRow;
                final title = CatalogTitle.fromMap(content);
                final progress = content['progress'] as SocialRow?;
                return PosterCard(
                  poster: title.poster,
                  title: title.name,
                  caption: progress == null
                      ? title.caption
                      : '${progress['watched']}/${progress['released']} episodes',
                  score: content['score'] as num?,
                  onTap: () => context.push(title.location),
                );
              },
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _failed
                ? InlineNotice(
                    'Could not load this list.',
                    icon: PhosphorIconsRegular.warningCircle,
                    action: 'Retry',
                    onAction: () => _load(more: _rows.isNotEmpty),
                  )
                : _working
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _rows.isEmpty
                ? Text(
                    switch (_section) {
                      'wanted' => 'Nothing in Want yet.',
                      'watched_movies' => 'No watched movies yet.',
                      'watched_shows' => 'No series yet.',
                      _ => 'No reviews yet.',
                    },
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: mutedColor),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// Sort menu plus direction toggle for a profile library section.
class _LibrarySortBar extends StatelessWidget {
  const _LibrarySortBar({
    required this.owner,
    required this.section,
    required this.sort,
    required this.ascending,
    required this.onChanged,
  });

  final String owner, section, sort;
  final bool ascending;
  final void Function(String sort, bool ascending) onChanged;

  /// Episode count only exists for shows; other sections fall back to activity.
  static String fit(String sort, String section) =>
      sort == 'episodes' && section != 'watched_shows' ? 'activity' : sort;

  @override
  Widget build(BuildContext context) {
    final sorts = [
      ('activity', section == 'wanted' ? 'Date added' : 'Recent activity'),
      (
        'rating',
        context.read<AccountCubit>().state.userId == owner
            ? 'My rating'
            : 'Their rating',
      ),
      ('imdb', 'IMDb rating'),
      ('release', 'Release year'),
      if (section == 'watched_shows') ('episodes', 'Number of episodes'),
    ];
    return Row(
      children: [
        PopupMenuButton<String>(
          tooltip: 'Sort by',
          initialValue: sort,
          // Activity reads newest first; the others read best/highest first.
          onSelected: (value) => onChanged(value, false),
          itemBuilder: (context) => [
            for (final (value, text) in sorts)
              PopupMenuItem(value: value, child: Text(text)),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sorts.firstWhere((item) => item.$1 == sort).$2,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 4),
                const Icon(PhosphorIconsRegular.caretDown, size: 16),
              ],
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: ascending ? 'Ascending' : 'Descending',
          onPressed: () => onChanged(sort, !ascending),
          icon: Icon(
            ascending
                ? PhosphorIconsRegular.sortAscending
                : PhosphorIconsRegular.sortDescending,
          ),
        ),
      ],
    );
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor(this.row);

  final SocialRow row;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final _name = TextEditingController(
    text: widget.row['display_name'] as String?,
  );
  late final _bio = TextEditingController(text: widget.row['bio'] as String?);
  late bool _private = widget.row['private'] == true;
  late String _audience =
      widget.row['library_audience'] as String? ?? 'only_me';

  @override
  void dispose() {
    for (final field in [_name, _bio]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      children: [
        Text('Edit profile', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        TextField(
          controller: _bio,
          maxLines: 3,
          maxLength: 500,
          decoration: const InputDecoration(labelText: 'Bio'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Private profile'),
          value: _private,
          subtitle: const Text(
            'Previously public content becomes follower-only.',
          ),
          onChanged: (value) => setState(() {
            _private = value;
            if (value && _audience == 'public') _audience = 'followers';
          }),
        ),
        DropdownButtonFormField<String>(
          initialValue: _audience,
          decoration: const InputDecoration(labelText: 'Library audience'),
          icon: const Icon(PhosphorIconsRegular.caretDown, size: 18),
          items: [
            for (final entry in audienceLabels.entries)
              if (!_private || entry.key != 'public')
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) => setState(() => _audience = value!),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'display_name': _name.text.trim(),
            'bio': _bio.text.trim(),
            'private': _private,
            'library_audience': _audience,
          }),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class RelationshipPage extends StatefulWidget {
  const RelationshipPage({super.key, required this.id, required this.kind});

  final String id;
  final String kind;

  @override
  State<RelationshipPage> createState() => _RelationshipPageState();
}

class PersonLibraryPage extends StatefulWidget {
  const PersonLibraryPage({super.key, required this.id});

  final String id;

  @override
  State<PersonLibraryPage> createState() => _PersonLibraryPageState();
}

class _PersonLibraryPageState extends State<PersonLibraryPage> {
  String _section = 'watched_movies';
  String _sort = 'activity';
  bool _ascending = false;
  List<SocialRow> _rows = [];
  bool _working = true, _failed = false, _more = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    final request = ++_request;
    setState(() {
      _working = true;
      _failed = false;
      if (!more) _rows = [];
    });
    try {
      final last = more ? _rows.lastOrNull : null;
      final rows = await context.read<SocialRepository>().many(
        'profile_library',
        {
          'owner_id': widget.id,
          'section': _section,
          'sort': _sort,
          'ascending': _ascending,
          'before_value': ?last?['sort_value'],
          'before_title': ?last?['title']?['id'],
        },
      );
      if (mounted && request == _request) {
        setState(() {
          _rows = [..._rows, ...rows];
          _more = rows.length == 20;
        });
      }
    } on Exception {
      if (mounted && request == _request) setState(() => _failed = true);
    } finally {
      if (mounted && request == _request) setState(() => _working = false);
    }
  }

  Widget _tile(SocialRow row) {
    final content = row['title'] as SocialRow;
    final title = CatalogTitle.fromMap(content);
    final progress = content['progress'] as SocialRow?;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(width: 48, height: 72, child: Artwork(title.poster)),
      trailing: switch (content['score']) {
        final num score => ScoreBadge(score),
        _ => null,
      },
      title: Text(title.name),
      subtitle: Text(
        [
          title.caption,
          if (progress != null)
            '${progress['watched']} of ${progress['released']} known episodes',
        ].join(' · '),
      ),
      onTap: () => context.push(title.location),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Library')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: 'watched_movies',
              label: Text('Movies'),
              tooltip: 'Watched movies',
            ),
            ButtonSegment(
              value: 'watched_shows',
              label: Text('Shows'),
              tooltip: 'Watched Shows',
            ),
            ButtonSegment(
              value: 'wanted',
              label: Text('Want'),
              tooltip: 'Want',
            ),
          ],
          selected: {_section},
          onSelectionChanged: (value) {
            _section = value.first;
            _sort = _LibrarySortBar.fit(_sort, _section);
            _load();
          },
        ),
        const SizedBox(height: 8),
        _LibrarySortBar(
          owner: widget.id,
          section: _section,
          sort: _sort,
          ascending: _ascending,
          onChanged: (sort, ascending) {
            _sort = sort;
            _ascending = ascending;
            _load();
          },
        ),
        const SizedBox(height: 4),
        if (_working) const LinearProgressIndicator(),
        if (_failed)
          InlineNotice(
            'Could not load this library.',
            icon: PhosphorIconsRegular.warningCircle,
            action: 'Retry',
            onAction: _load,
          ),
        if (!_working && !_failed && _rows.isEmpty)
          const EmptyState(
            icon: PhosphorIconsRegular.filmStrip,
            title: 'Nothing here',
            message: 'No visible titles in this section.',
          ),
        for (final row in _rows) _tile(row),
        if (_more && !_working)
          TextButton(
            onPressed: () => _load(more: true),
            child: const Text('Load more'),
          ),
      ],
    ),
  );
}

class _RelationshipPageState extends State<RelationshipPage> {
  List<SocialRow> _rows = [];
  bool _loading = true, _error = false, _more = false;

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
      final repo = context.read<SocialRepository>();
      final rows = widget.kind == 'blocked'
          ? await repo.many('blocked_profiles')
          : await repo.many('relationship_page', {
              'target': widget.id,
              'list_type': widget.kind,
              if (append && _rows.isNotEmpty)
                'before_handle': _rows.last['handle'],
            });
      if (mounted) {
        setState(() {
          _rows = append ? [..._rows, ...rows] : rows;
          _more = widget.kind != 'blocked' && rows.length == 20;
        });
      }
    } on Exception {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _action(SocialRow row, String decision) async {
    try {
      final repo = context.read<SocialRepository>();
      await (widget.kind == 'blocked'
          ? repo.change('set_block', {
              'target': row['user_id'],
              'blocked': false,
            })
          : repo.change('resolve_follow_request', {
              'target': row['user_id'],
              'decision': decision,
            }));
      if (mounted) await _load();
    } on Exception {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final own = widget.id == context.watch<AccountCubit>().state.userId;
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (widget.kind) {
          'requests' => 'Follow requests',
          'followers' => 'Followers',
          'blocked' => 'Blocked profiles',
          _ => 'Following',
        }),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error)
            TextButton(
              onPressed: _load,
              child: const Text('Could not load. Retry'),
            ),
          if (!_loading && !_error && _rows.isEmpty)
            const Text('No profiles to show.'),
          for (final row in _rows)
            _PersonTile(
              row,
              action: switch (widget.kind) {
                'requests' => PopupMenuButton<String>(
                  tooltip: 'Request actions',
                  icon: const Icon(PhosphorIconsRegular.dotsThree),
                  onSelected: (choice) => _action(row, choice),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'approve', child: Text('Approve')),
                    PopupMenuItem(value: 'decline', child: Text('Decline')),
                  ],
                ),
                'blocked' => TextButton(
                  onPressed: () => _action(row, 'unblock'),
                  child: const Text('Unblock'),
                ),
                'followers' when own => TextButton(
                  onPressed: () => _action(row, 'remove'),
                  child: const Text('Remove'),
                ),
                _ => null,
              },
            ),
          if (_more && !_loading)
            TextButton(
              onPressed: () => _load(append: true),
              child: const Text('Load more'),
            ),
        ],
      ),
    );
  }
}
