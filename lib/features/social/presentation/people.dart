import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';
import '../../../core/backend_config.dart';
import '../../auth/auth_cubit.dart';
import '../../catalog/data/catalog_repository.dart';
import '../../catalog/presentation/artwork.dart';
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
  void dispose() { _debounce?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Find people')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      TextField(
        autofocus: true, decoration: const InputDecoration(labelText: 'Search handles', prefixIcon: Icon(Icons.search)),
        onChanged: (text) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), () {
            if (mounted) setState(() => _results = context.read<SocialRepository>().findPeople(text));
          });
        },
      ),
      FutureBuilder(future: _results, builder: (context, result) {
        if (result.connectionState == ConnectionState.waiting) return const LinearProgressIndicator();
        if (result.hasError) return const Text('Search is temporarily unavailable.');
        final rows = result.data;
        if (rows == null) return const SizedBox.shrink();
        if (rows.isEmpty) return const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No matching profiles.'));
        return Column(children: [for (final row in rows) _PersonTile(row)]);
      }),
    ]),
  );
}

class _PersonTile extends StatelessWidget {
  const _PersonTile(this.row, {this.action});
  final SocialRow row;
  final Widget? action;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: _Initial(row['handle'] as String, size: 40),
    title: Text(row['display_name'] as String? ?? '@${row['handle']}'),
    subtitle: row['display_name'] == null ? null : Text('@${row['handle']}'),
    trailing: action,
    onTap: () => context.push('/people/${row['user_id']}'),
  );
}

class _Initial extends StatelessWidget {
  const _Initial(this.handle, {this.size = 32});
  final String handle;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size, alignment: Alignment.center,
    decoration: const BoxDecoration(shape: BoxShape.circle, color: selectedColor),
    child: Text(handle.isEmpty ? '?' : handle[0].toUpperCase(),
      style: TextStyle(fontFamily: 'Instrument Serif', fontSize: size * .5, color: coralColor)),
  );
}

class FollowingPage extends StatefulWidget {
  const FollowingPage({super.key});
  @override
  State<FollowingPage> createState() => _FollowingPageState();
}

class _FollowingPageState extends State<FollowingPage> {
  List<SocialRow> _rows = [];
  bool _working = false, _failed = false, _more = false, _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool append = false}) async {
    if (!mounted || _working || context.read<AccountCubit>().state.phase != AccountPhase.ready) return;
    final owner = context.read<AccountCubit>().state.userId;
    setState(() { _working = true; _failed = false; });
    try {
      final rows = await context.read<SocialRepository>().feed(after: append ? _rows.lastOrNull : null);
      if (!mounted || owner != context.read<AccountCubit>().state.userId) return;
      setState(() { _loaded = true; _rows = append ? [..._rows, ...rows] : rows; _more = rows.length == 20; });
    } on Exception {
      if (mounted) setState(() => _failed = true);
    } finally { if (mounted) setState(() => _working = false); }
  }

  @override
  Widget build(BuildContext context) {
    final ready = context.watch<AccountCubit>().state.phase == AccountPhase.ready;
    return BlocListener<AccountCubit, Account>(
      listener: (context, user) {
        if (user.phase == AccountPhase.ready) {
          _load();
        } else {
          setState(() { _rows = []; _loaded = false; _more = false; });
        }
      },
      child: !ready
        ? Center(child: TextButton(onPressed: () => context.push('/account'), child: const Text('Sign in to follow activity')))
        : RefreshIndicator(onRefresh: _load, child: ListView(
          physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            if (_working) const LinearProgressIndicator(),
            if (_failed) TextButton(onPressed: _load, child: const Text('Could not load Following. Retry')),
            if (_loaded && _rows.isEmpty)
              EmptyState(
                icon: Icons.people_outline,
                title: 'Your feed is quiet',
                message: 'Follow friends to see what they watch, rate and review.',
                action: FilledButton.icon(onPressed: () => context.push('/people'),
                  icon: const Icon(Icons.person_add_alt, size: 20), label: const Text('Find people')),
              ),
            for (final (index, row) in _rows.indexed) ...[
              if (index > 0) const Divider(),
              Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Row(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  InkWell(
                    onTap: () => context.push('/people/${row['actor_id']}'),
                    customBorder: const CircleBorder(),
                    child: _Initial(row['handle'] as String),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    GestureDetector(
                      onTap: () => context.push('/people/${row['actor_id']}'),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(text: '@${row['handle']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        TextSpan(text: switch (row['kind']) {
                          _ when row['review'] != null => ' reviewed',
                          'rating' => ' rated',
                          'first_show' => ' started watching',
                          _ => ' watched',
                        }, style: const TextStyle(color: mutedColor)),
                      ]), style: const TextStyle(fontSize: 15)),
                    ),
                    if (row['review'] case final SocialRow review) ReviewTile(review, showTitle: true)
                    else InkWell(
                      onTap: () => context.push('/titles/${row['media']}/${row['tmdb_id']}'),
                      child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${row['title']}${row['season'] == null ? '' : ' · ${row['season']}'}',
                            style: Theme.of(context).textTheme.titleMedium),
                          if (row['kind'] == 'rating')
                            Row(children: [
                              const Icon(Icons.star_rounded, size: 16, color: coralColor),
                              const SizedBox(width: 4),
                              Text('${(row['score'] as int) / 2} of 5', style: Theme.of(context).textTheme.bodySmall),
                            ]),
                        ],
                      )),
                    ),
                  ])),
                ],
              )),
            ],
            if (_more && !_working) TextButton(onPressed: () => _load(append: true), child: const Text('Load more')),
          ],
        )),
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
  Future<SocialRow?> _fetch() => context.read<SocialRepository>().one('profile_page', {'target': widget.id});

  Future<void> _change(String rpc, SocialRow params) async {
    try {
      await context.read<SocialRepository>().change(rpc, params);
      if (mounted) setState(() => _profile = _fetch());
    } on Exception {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save. Try again.')));
    }
  }

  Future<void> _edit(SocialRow row) async {
    final update = await showModalBottomSheet<SocialRow>(
      context: context, isScrollControlled: true, builder: (context) => _ProfileEditor(row),
    );
    if (update != null && mounted) await _change('profile_update', {'fields': update});
  }

  Future<void> _changeAvatar(bool remove) async {
    final repository = context.read<SocialRepository>();
    try {
      if (remove) {
        await repository.changeAvatar(null);
      } else {
        final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 384, maxHeight: 384,
          requestFullMetadata: false);
        if (file == null) return;
        if (await file.length() > 8 * 1024 * 1024) throw const FormatException('Image too large');
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        try {
          final frame = await codec.getNextFrame();
          try {
            if (frame.image.width > 512 || frame.image.height > 512) throw const FormatException('Image too large');
            final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
            if (data == null || data.lengthInBytes > 1024 * 1024) throw const FormatException('Image too large');
            await repository.changeAvatar(data.buffer.asUint8List(data.offsetInBytes,data.lengthInBytes));
          } finally { frame.image.dispose(); }
        } finally { codec.dispose(); }
      }
      if (mounted) setState(() => _avatarVersion++);
    } on Object {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not update your profile photo.')));
    }
  }

  Future<void> _photoSheet() async {
    final remove = await showModalBottomSheet<bool>(context: context, builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.photo_outlined), title: const Text('Choose photo'),
          onTap: () => Navigator.pop(context, false)),
        ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Remove photo'),
          onTap: () => Navigator.pop(context, true)),
      ]),
    ));
    if (remove != null && mounted) await _changeAvatar(remove);
  }

  Future<void> _settingsSheet() async {
    final route = await showModalBottomSheet<String>(context: context, builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final (icon, label, value) in [
          (Icons.account_circle_outlined, 'Profile photo', 'photo'),
          (Icons.person_add_alt, 'Follow requests', '/people/${widget.id}/requests'),
          (Icons.block, 'Blocked profiles', '/blocked-people'),
          (Icons.notifications_none, 'Notification settings', '/notification-settings'),
          (Icons.manage_accounts_outlined, 'Account', '/account'),
        ])
          ListTile(leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(context, value)),
      ]),
    ));
    if (route == null || !mounted) return;
    if (route == 'photo') {
      await _photoSheet();
    } else {
      await context.push(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = FutureBuilder(
      future: _profile,
      builder: (context, result) {
        if (result.hasError) {
          return Center(child: TextButton(onPressed: () => setState(() => _profile = _fetch()),
            child: const Text('Could not load profile. Retry')));
        }
        if (result.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final row = result.data;
        if (row == null) return const Center(child: Text('This profile is unavailable.'));
        final own = row['own'] == true;
        final ready = context.watch<AccountCubit>().state.phase == AccountPhase.ready;
        final relationship = row['relationship'];
        final handle = row['handle'] as String;
        final name = row['display_name'] as String?;
        final initials = Center(child: Text(handle[0].toUpperCase(),
          style: const TextStyle(fontFamily: 'Instrument Serif', fontSize: 36, color: coralColor)));
        final followLabel = switch (relationship) {
          'accepted' => 'Following', 'pending' => 'Requested', _ => row['private'] == true ? 'Request to follow' : 'Follow',
        };
        void follow() => ready
          ? _change('set_follow', {'target': widget.id, 'follow': relationship == null})
          : context.push('/account');
        final stats = [
          if (row['can_read'] == true) ...[
            ('${row['followers']}', 'followers', () => context.push('/people/${widget.id}/followers')),
            ('${row['following']}', 'following', () => context.push('/people/${widget.id}/following')),
          ],
          if (row['can_read_library'] == true) ...[
            ('${row['movies']}', 'movies', null),
            ('${row['shows']}', 'shows', null),
            ('${row['episodes']}', 'episodes', null),
          ],
        ];
        final links = [
          if (row['can_read'] == true)
            (Icons.rate_review_outlined, 'Reviews', () => context.push('/review-list?author=${widget.id}')),
          if (own)
            (Icons.video_library_outlined, 'Library', () => context.go('/library'))
          else if (row['can_read_library'] == true)
            (Icons.video_library_outlined, 'Library', () => context.push('/people/${widget.id}/library')),
        ];
        return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          Row(children: [
            Semantics(
              button: own, label: own ? 'Change profile photo' : null,
              child: GestureDetector(
                onTap: own ? () => _photoSheet() : null,
                child: Container(
                  width: 72, height: 72, clipBehavior: Clip.antiAlias,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: selectedColor),
                  child: row['can_read'] == true ? Image.network(
                    '$backendUrl/functions/v1/avatar?user=${widget.id}&v=$_avatarVersion',
                    headers: context.read<SocialRepository>().avatarHeaders, fit: BoxFit.cover,
                    errorBuilder: (_,_,_) => initials,
                  ) : initials,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name ?? handle, style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 4),
              Row(children: [
                Flexible(child: Text('@$handle', style: const TextStyle(fontSize: 15, color: mutedColor))),
                if (row['private'] == true) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.lock_outline, size: 14, color: mutedColor, semanticLabel: 'Private profile'),
                ],
              ]),
            ])),
          ]),
          if (row['bio'] case final String bio when bio.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 16), child: Text(bio)),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(children: [
              for (final (value, label, onTap) in stats)
                Expanded(child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
                    Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600,
                      fontFeatures: [ui.FontFeature.tabularFigures()])),
                    Text(label, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
                  ])),
                )),
            ]),
          ],
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: own
              ? OutlinedButton(onPressed: () => _edit(row), child: const Text('Edit profile'))
              : relationship == null
                ? FilledButton(onPressed: follow, child: Text(followLabel))
                : OutlinedButton(onPressed: follow, child: Text(followLabel))),
            if (own || ready) ...[
              const SizedBox(width: 8),
              own
                ? IconButton.outlined(
                    tooltip: 'Settings', onPressed: _settingsSheet,
                    style: IconButton.styleFrom(side: const BorderSide(color: hairlineColor),
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
                      minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.settings_outlined))
                : PopupMenuButton<String>(
                    tooltip: 'More actions',
                    onSelected: (choice) => choice == 'report'
                      ? reportSocial(context, widget.id, 'profile')
                      : _change('set_block', {'target': widget.id, 'blocked': true}),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'report', child: Text('Report')),
                      PopupMenuItem(value: 'block', child: Text('Block')),
                    ],
                    child: Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(border: Border.all(color: hairlineColor), borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.more_horiz),
                    ),
                  ),
            ],
          ]),
          if (links.isNotEmpty) ...[
            const SizedBox(height: 32),
            Material(
              color: surfaceColor,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (final (index, (icon, label, onTap)) in links.indexed) ...[
                  if (index > 0) const Divider(indent: 56),
                  ListTile(leading: Icon(icon), title: Text(label),
                    trailing: const Icon(Icons.chevron_right), onTap: onTap),
                ],
              ]),
            ),
          ],
        ]);
      },
    );
    return widget.inTab ? body : Scaffold(appBar: AppBar(title: const Text('Profile')), body: body);
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor(this.row);
  final SocialRow row;
  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final _name = TextEditingController(text: widget.row['display_name'] as String?);
  late final _bio = TextEditingController(text: widget.row['bio'] as String?);
  late final _market = TextEditingController(text: widget.row['market'] as String?);
  late final _timezone = TextEditingController(text: widget.row['timezone'] as String?);
  late bool _private = widget.row['private'] == true;
  late bool _tracking = widget.row['tracking_activity'] == true;
  late String _audience = widget.row['library_audience'] as String? ?? 'only_me';
  @override
  void dispose() {
    for (final field in [_name,_bio,_market,_timezone]) { field.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(child: ListView(
    shrinkWrap: true, padding: EdgeInsets.fromLTRB(16,16,16,16 + MediaQuery.viewInsetsOf(context).bottom),
    children: [
      Text('Edit profile', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 16),
      TextField(controller: _name, maxLength: 80, decoration: const InputDecoration(labelText: 'Display name')),
      TextField(controller: _bio, maxLines: 3, maxLength: 500, decoration: const InputDecoration(labelText: 'Bio')),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Private profile'), value: _private,
        subtitle: const Text('Previously public content becomes follower-only.'),
        onChanged: (value) => setState(() { _private = value; if (value && _audience == 'public') _audience = 'followers'; })),
      DropdownButtonFormField<String>(
        initialValue: _audience, decoration: const InputDecoration(labelText: 'Library audience'),
        items: [for (final entry in audienceLabels.entries) if (!_private || entry.key != 'public')
          DropdownMenuItem(value: entry.key, child: Text(entry.value))],
        onChanged: (value) => setState(() => _audience = value!),
      ),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Share first watches'), value: _tracking,
        onChanged: (value) => setState(() => _tracking = value)),
      TextField(controller: _market, maxLength: 2, textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(labelText: 'Release market', hintText: 'KZ')),
      TextField(controller: _timezone, decoration: const InputDecoration(labelText: 'Time zone', hintText: 'Asia/Qyzylorda')),
      const SizedBox(height: 16),
      FilledButton(onPressed: () => Navigator.pop(context, {
        'display_name': _name.text.trim(), 'bio': _bio.text.trim(), 'private': _private, 'library_audience': _audience,
        'tracking_activity': _tracking, 'market': _market.text.trim().isEmpty ? null : _market.text.trim().toUpperCase(),
        'timezone': _timezone.text.trim().isEmpty ? null : _timezone.text.trim(),
      }), child: const Text('Save')),
    ],
  ));
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
  List<SocialRow> _rows = [];
  bool _working = true, _failed = false, _more = false;
  int _request = 0;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load({bool more = false}) async {
    final request = ++_request;
    setState(() { _working = true; _failed = false; if (!more) _rows = []; });
    try {
      final last = more ? _rows.lastOrNull : null;
      final rows = await context.read<SocialRepository>().many('profile_library', {
        'owner_id': widget.id, 'section': _section,
        'before_time': ?last?['activity_at'], 'before_title': ?last?['title']?['id'],
      });
      if (mounted && request == _request) {
        setState(() {
          _rows = [..._rows,...rows];
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
      title: Text(title.name),
      subtitle: Text( [title.caption, if (progress != null) '${progress['watched']} of ${progress['released']} known episodes'].join(' · ')),
      onTap: () => context.push(title.location),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Library')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, children: [
        for (final (section,label) in const [('watched_movies','Watched Movies'),('watched_shows','Watched Shows'),('wanted','Wanted')])
          ChoiceChip(label: Text(label), selected: _section == section, onSelected: (_) {
            if (_section == section) return;
            _section = section;
            _load();
          }),
      ]),
      if (_working) const LinearProgressIndicator(),
      if (_failed) TextButton(onPressed: _load, child: const Text('Could not load this library. Retry')),
      if (!_working && !_failed && _rows.isEmpty) const Text('No visible titles.'),
      for (final row in _rows) _tile(row),
      if (_more && !_working) TextButton(onPressed: () => _load(more: true), child: const Text('Load more')),
    ]),
  );
}

class _RelationshipPageState extends State<RelationshipPage> {
  List<SocialRow> _rows = [];
  bool _loading = true, _error = false, _more = false;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load({bool append = false}) async {
    setState(() { _loading = true; _error = false; });
    try {
      final repo = context.read<SocialRepository>();
      final rows = widget.kind == 'blocked'
        ? await repo.many('blocked_profiles')
        : await repo.many('relationship_page', {
          'target': widget.id, 'list_type': widget.kind,
          if (append && _rows.isNotEmpty) 'before_handle': _rows.last['handle'],
        });
      if (mounted) {
        setState(() {
          _rows = append ? [..._rows,...rows] : rows;
          _more = widget.kind != 'blocked' && rows.length == 20;
        });
      }
    } on Exception { if (mounted) setState(() => _error = true); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  Future<void> _action(SocialRow row, String decision) async {
    try {
      final repo = context.read<SocialRepository>();
      await (widget.kind == 'blocked'
        ? repo.change('set_block', {'target': row['user_id'], 'blocked': false})
        : repo.change('resolve_follow_request', {'target': row['user_id'], 'decision': decision}));
      if (mounted) await _load();
    } on Exception { if (mounted) setState(() => _error = true); }
  }
  @override
  Widget build(BuildContext context) {
    final own = widget.id == context.watch<AccountCubit>().state.userId;
    return Scaffold(
      appBar: AppBar(title: Text(switch (widget.kind) {
        'requests' => 'Follow requests', 'followers' => 'Followers', 'blocked' => 'Blocked profiles', _ => 'Following',
      })),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error) TextButton(onPressed: _load, child: const Text('Could not load. Retry')),
        if (!_loading && !_error && _rows.isEmpty) const Text('No profiles to show.'),
        for (final row in _rows) _PersonTile(row, action: switch (widget.kind) {
          'requests' => PopupMenuButton<String>(
            tooltip: 'Request actions', onSelected: (choice) => _action(row, choice),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'approve', child: Text('Approve')),
              PopupMenuItem(value: 'decline', child: Text('Decline')),
            ],
          ),
          'blocked' => TextButton(onPressed: () => _action(row, 'unblock'), child: const Text('Unblock')),
          'followers' when own => TextButton(onPressed: () => _action(row, 'remove'), child: const Text('Remove')),
          _ => null,
        }),
        if (_more && !_loading) TextButton(onPressed: () => _load(append: true), child: const Text('Load more')),
      ]),
    );
  }
}
