import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/phosphor.dart';
import '../../app/theme.dart';
import '../auth/auth_cubit.dart';
import '../catalog/data/catalog_repository.dart';
import '../catalog/presentation/artwork.dart';
import 'notifications.dart';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key, this.initialId});
  final String? initialId;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final _items = <bool, List<InboxItem>>{true: [], false: []};
  final _more = <bool, bool>{true: false, false: false};
  late final StreamSubscription<void> _refresh;
  bool _working = false;
  bool _error = false;
  bool _loaded = false;
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _refresh = context.read<AndroidPush>().changes.listen((_) => _load());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onReady());
  }

  @override
  void dispose() {
    _refresh.cancel();
    super.dispose();
  }

  Future<void> _onReady() async {
    if (!mounted ||
        context.read<AccountCubit>().state.phase != AccountPhase.ready) {
      return;
    }
    await _load();
    if (!mounted || _opened || widget.initialId == null) return;
    _opened = true;
    await _open(widget.initialId!);
  }

  Future<void> _load({bool? more}) async {
    if (!mounted ||
        _working ||
        context.read<AccountCubit>().state.phase != AccountPhase.ready) {
      return;
    }
    final owner = context.read<AccountCubit>().state.userId;
    final repo = context.read<InboxRepository>();
    setState(() {
      _working = true;
      _error = false;
    });
    try {
      if (more != null) {
        final page = await repo.items(
          people: more,
          after: _items[more]!.lastOrNull,
        );
        if (!mounted || owner != context.read<AccountCubit>().state.userId) {
          return;
        }
        setState(() {
          _items[more] = [..._items[more]!, ...page];
          _more[more] = page.length == 20;
        });
        return;
      }
      final (people, titles) = await (
        repo.items(people: true),
        repo.items(people: false),
      ).wait;
      if (!mounted || owner != context.read<AccountCubit>().state.userId) {
        return;
      }
      setState(() {
        _loaded = true;
        _items[true] = people;
        _items[false] = titles;
        _more[true] = people.length == 20;
        _more[false] = titles.length == 20;
      });
      final newest = [people.firstOrNull, titles.firstOrNull].nonNulls
          .fold<InboxItem?>(
            null,
            (best, item) => best == null || _after(item, best) ? item : best,
          );
      if ([...people, ...titles].any((item) => !item.read)) {
        await repo.read(through: newest);
      }
    } on Exception {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  static bool _after(InboxItem a, InboxItem b) {
    final order = DateTime.parse(a.eventAt)
        .compareTo(DateTime.parse(b.eventAt));
    return order > 0 || order == 0 && a.id.compareTo(b.id) > 0;
  }

  Future<void> _open(String id) async {
    final repo = context.read<InboxRepository>();
    try {
      final item = (await repo.items(id: id)).firstOrNull;
      if (!mounted) return;
      if (item == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This update is unavailable.')),
        );
        return;
      }
      await repo.read(id: id);
      if (!mounted) return;
      String? route;
      if (item.kind == 'follow_request') {
        route = '/people/me/requests';
      } else if (item.kind == 'follow' || item.kind == 'follow_accepted') {
        route = '/people/${item.target}';
      } else if (item.kind == 'like' || item.kind == 'comment') {
        route = '/reviews/${item.target}';
      } else if (item.kind == 'import_done') {
        route = '/import-must';
      } else {
        final title = await repo.client
            .schema('api')
            .from('titles')
            .select()
            .eq('id', item.target)
            .maybeSingle();
        if (title != null) route = CatalogTitle.fromMap(title).location;
      }
      if (!mounted) return;
      if (route != null) await context.push(route);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this update.')),
        );
      }
    }
  }

  Widget _tab(String label, bool people) {
    final unread = _grouped(_items[people]!)
        .where((row) => !row.$1.read)
        .length;
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (unread > 0) ...[
            const SizedBox(width: 6),
            Badge.count(
              count: unread,
              backgroundColor: const Color(0xffff3b30),
              textColor: Colors.white,
            ),
          ],
        ],
      ),
    );
  }

  static List<(InboxItem, int)> _grouped(List<InboxItem> items) {
    final rows = <(InboxItem, int)>[];
    final index = <String, int>{};
    for (final item in items) {
      if (item.kind != 'episode') {
        rows.add((item, 1));
        continue;
      }
      final day = DateUtils.dateOnly(DateTime.parse(item.eventAt).toLocal());
      final key = '${item.target}:$day';
      final at = index[key];
      if (at == null) {
        index[key] = rows.length;
        rows.add((item, 1));
        continue;
      }
      final (first, count) = rows[at];
      rows[at] = (
        (
          id: first.id,
          kind: first.kind,
          target: first.target,
          eventAt: first.eventAt,
          read: first.read && item.read,
          message: first.message,
          actorId: first.actorId,
          handle: first.handle,
          poster: first.poster,
          title: first.title,
        ),
        count + 1,
      );
    }
    return rows;
  }

  Widget _list(bool people) {
    final items = _items[people]!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_working && !_loaded)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Skeleton(),
            ),
          if (_error)
            TextButton(
              onPressed: _load,
              child: const Text('Could not load updates. Retry'),
            ),
          if (_loaded && !_error && items.isEmpty)
            EmptyState(
              icon: people
                  ? PhosphorIconsRegular.users
                  : PhosphorIconsRegular.filmStrip,
              title: 'Nothing here yet',
              message: people
                  ? 'New followers, likes and comments show up here.'
                  : 'New episodes and Want releases show up here.',
            ),
          for (final (item, count) in _grouped(items))
            _InboxRow(item, count: count, onTap: () => _open(item.id)),
          if (_more[people]!)
            TextButton(
              onPressed: _working ? null : () => _load(more: people),
              child: const Text('Load more'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    final ready = account.phase == AccountPhase.ready;
    return BlocListener<AccountCubit, Account>(
      listener: (context, account) {
        if (account.phase == AccountPhase.ready) {
          unawaited(_onReady());
        } else {
          setState(() {
            _items[true] = [];
            _items[false] = [];
            _loaded = false;
            _opened = false;
          });
        }
      },
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Notifications'),
            actions: [
              IconButton(
                tooltip: 'Notification preferences',
                onPressed: () => context.push('/notification-settings'),
                icon: const Icon(PhosphorIconsRegular.slidersHorizontal),
              ),
            ],
            bottom: ready
                ? TabBar(
                    tabs: [_tab('People', true), _tab('Movies & shows', false)],
                  )
                : null,
          ),
          body: ready
              ? TabBarView(children: [_list(true), _list(false)])
              : Center(
                  child: TextButton(
                    onPressed: () => context.push('/account'),
                    child: const Text('Sign in to see your notifications'),
                  ),
                ),
        ),
      ),
    );
  }
}

class _InboxRow extends StatelessWidget {
  const _InboxRow(this.item, {required this.onTap, this.count = 1});

  final InboxItem item;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    final handle = item.handle;
    final message = count > 1
        ? '$count new episodes of ${item.title ?? 'a show you watch'}'
        : item.message ?? '';
    final Widget leading = switch (item.kind) {
      'import_done' => const SizedBox(
        width: 44,
        height: 44,
        child: Icon(PhosphorIconsRegular.downloadSimple, color: mutedColor),
      ),
      'episode' || 'wanted_release' => SizedBox(
        width: 44,
        height: 66,
        child: Artwork(item.poster, radius: 6),
      ),
      _ => Avatar(handle ?? '', userId: item.actorId, size: 44),
    };
    final named = handle != null && message.startsWith('@$handle');
    return Material(
      color: item.read ? Colors.transparent : selectedColor,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          if (named)
                            TextSpan(
                              text: '@$handle',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          TextSpan(
                            text: named
                                ? message.substring(handle.length + 1)
                                : message,
                          ),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, color: inkColor),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      timeAgo(item.eventAt),
                      style: const TextStyle(fontSize: 13, color: mutedColor),
                    ),
                  ],
                ),
              ),
              if (!item.read)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Semantics(
                    label: 'New',
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: coralColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  late Future<Map<String, NoticePreference>> _settings = context
      .read<InboxRepository>()
      .preferences();
  bool _saving = false;

  Future<void> _set(String category, NoticePreference value) async {
    final push = context.read<AndroidPush>();
    final repo = context.read<InboxRepository>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      if (value.push && !await push.requestPermission()) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Allow notifications in Android settings to enable push.',
            ),
          ),
        );
        return;
      }
      await repo.setPreference(category, value);
      await push.refreshBinding();
    } on Object {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not update delivery. Check your connection and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _settings = repo.preferences();
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notification preferences')),
    body: FutureBuilder(
      future: _settings,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() {
                _settings = context.read<InboxRepository>().preferences();
              }),
              child: const Text('Could not load preferences. Retry'),
            ),
          );
        }
        final values = snapshot.data;
        if (values == null) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: const [Skeleton(rows: 5, leading: 24)],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!AndroidPush.supported)
              const Text('In-app notifications are available on this device.'),
            for (final (category, name) in const [
              ('social', 'Social activity'),
              ('episodes', 'New episodes'),
              ('wanted', 'Want releases'),
            ]) ...[
              Text(name, style: Theme.of(context).textTheme.titleLarge),
              SwitchListTile(
                title: const Text('In app'),
                value: values[category]!.inbox,
                onChanged: _saving
                    ? null
                    : (enabled) =>
                          _set(category, (inbox: enabled, push: false)),
              ),
              if (AndroidPush.supported)
                SwitchListTile(
                  title: const Text('Push'),
                  value: values[category]!.push,
                  onChanged: _saving || !values[category]!.inbox
                      ? null
                      : (enabled) =>
                            _set(category, (inbox: true, push: enabled)),
                ),
              const SizedBox(height: 16),
            ],
          ],
        );
      },
    ),
  );
}
