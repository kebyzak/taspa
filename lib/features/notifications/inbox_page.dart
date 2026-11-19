import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/phosphor.dart';
import '../auth/auth_cubit.dart';
import '../catalog/data/catalog_repository.dart';
import 'notifications.dart';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key, this.initialId});
  final String? initialId;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  List<InboxItem> _items = [];
  late final StreamSubscription<void> _refresh;
  bool _working = false;
  bool _error = false;
  bool _more = false;
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

  Future<void> _load({bool more = false}) async {
    if (!mounted ||
        _working ||
        context.read<AccountCubit>().state.phase != AccountPhase.ready) {
      return;
    }
    final owner = context.read<AccountCubit>().state.userId;
    setState(() {
      _working = true;
      _error = false;
    });
    try {
      final page = await context.read<InboxRepository>().items(
        after: more ? _items.lastOrNull : null,
      );
      if (!mounted || owner != context.read<AccountCubit>().state.userId) {
        return;
      }
      setState(() {
        _items = more ? [..._items, ...page] : page;
        _more = page.length == 20;
      });
    } on Exception {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
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
      if (mounted) await _load();
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this update.')),
        );
      }
    }
  }

  String _description(String kind) => switch (kind) {
    'follow' => 'New follower',
    'follow_request' => 'Follow request',
    'follow_accepted' => 'Follow request accepted',
    'like' => 'Someone liked your review',
    'comment' => 'New comment on your review',
    'episode' => 'New episode',
    'import_done' => 'Your Must import is finished',
    _ => 'A title from Want releases soon',
  };

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    return BlocListener<AccountCubit, Account>(
      listener: (context, account) {
        if (account.phase == AccountPhase.ready) {
          unawaited(_onReady());
        } else {
          setState(() {
            _items = [];
            _opened = false;
          });
        }
      },
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
        ),
        body: account.phase != AccountPhase.ready
            ? Center(
                child: TextButton(
                  onPressed: () => context.push('/account'),
                  child: const Text('Sign in to see your notifications'),
                ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_items.any((item) => !item.read))
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () async {
                            try {
                              await context.read<InboxRepository>().read(
                                through: _items.first,
                              );
                              await _load();
                            } on Exception {
                              if (mounted) setState(() => _error = true);
                            }
                          },
                          child: const Text('Mark all read'),
                        ),
                      ),
                    if (_working) const LinearProgressIndicator(),
                    if (_error)
                      TextButton(
                        onPressed: _load,
                        child: const Text('Could not load updates. Retry'),
                      ),
                    if (!_working && !_error && _items.isEmpty)
                      const Text('You’re all caught up.'),
                    for (final item in _items)
                      ListTile(
                        leading: Icon(
                          item.read
                              ? PhosphorIconsRegular.bell
                              : PhosphorIconsRegular.bellRinging,
                        ),
                        title: Text(item.message ?? _description(item.kind)),
                        subtitle: Text(
                          [
                            if (!item.read) 'Unread',
                            MaterialLocalizations.of(context).formatShortDate(
                              DateTime.parse(item.eventAt).toLocal(),
                            ),
                          ].join(' · '),
                        ),
                        onTap: () => _open(item.id),
                      ),
                    if (_more)
                      TextButton(
                        onPressed: _working ? null : () => _load(more: true),
                        child: const Text('Load more'),
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
          return const Center(child: CircularProgressIndicator());
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
                  title: const Text('Push on Android'),
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
