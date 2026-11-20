import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'phosphor.dart';
import '../core/offline_store.dart';
import '../features/auth/account_page.dart';
import '../features/auth/auth_cubit.dart';
import '../features/catalog/data/catalog_repository.dart';
import '../features/catalog/presentation/catalog_cubit.dart';
import '../features/catalog/presentation/discover_page.dart';
import '../features/catalog/presentation/title_detail_page.dart';
import '../features/library/data/library_repository.dart';
import '../features/library/presentation/library_page.dart';
import '../features/notifications/inbox_page.dart';
import '../features/notifications/notifications.dart';
import '../features/social/data/social_repository.dart';
import '../features/social/presentation/insights.dart';
import '../features/social/presentation/must_import.dart';
import '../features/social/presentation/people.dart';
import '../features/social/presentation/reviews.dart';
import 'theme.dart';

class TaspaApp extends StatefulWidget {
  const TaspaApp({super.key, required this.client});

  final SupabaseClient client;

  @override
  State<TaspaApp> createState() => _TaspaAppState();
}

class _TaspaAppState extends State<TaspaApp> with WidgetsBindingObserver {
  late final _account = AccountCubit(widget.client, _offline);
  final _offline = OfflineStore();
  late final _catalog = CatalogRepository(widget.client, _offline);
  late final _library = LibraryRepository(widget.client, _offline);
  late final _inbox = InboxRepository(widget.client);
  late final _push = AndroidPush(_inbox);
  late final _social = SocialRepository(widget.client);
  String? _pendingNotice;
  StreamSubscription<Uri>? _links;
  Timer? _syncTimer;
  String? _cacheOwner;
  late final GoRouter _router = GoRouter(
    initialLocation: '/discover',
    routes: [
      GoRoute(path: '/shows', redirect: (context, state) => '/library'),
      GoRoute(path: '/want', redirect: (context, state) => '/library'),
      GoRoute(path: '/following', redirect: (context, state) => '/feed'),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _Tabs(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/discover',
                builder: (context, state) => const DiscoverPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/library',
                builder: (context, state) => LibraryTab(
                  movies: state.uri.queryParameters['tab'] == 'movies',
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/feed',
                builder: (context, state) => const FollowingPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                builder: (context, state) => BlocBuilder<AccountCubit, Account>(
                  builder: (context, account) =>
                      account.phase == AccountPhase.ready
                      ? PersonPage(
                          id: account.userId!,
                          key: ValueKey(account.userId),
                          inTab: true,
                        )
                      : AccountPage(returnTo: state.extra as String?),
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/account',
        builder: (context, state) => Scaffold(
          appBar: AppBar(),
          body: AccountPage(returnTo: state.extra as String?),
        ),
      ),
      GoRoute(path: '/help', builder: (context, state) => const _HelpPage()),
      GoRoute(
        path: '/import-must',
        builder: (context, state) => const MustImportPage(),
      ),
      GoRoute(
        path: '/movies',
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Watched movies')),
          body: const LibraryPage(section: LibrarySection.watchedMovies),
        ),
      ),
      GoRoute(
        path: '/notifications',
        builder: (context, state) => InboxPage(
          initialId: state.uri.queryParameters['notice'],
          key: ValueKey(state.uri.queryParameters['notice']),
        ),
      ),
      GoRoute(
        path: '/notification-settings',
        builder: (context, state) => const NotificationSettingsPage(),
      ),
      GoRoute(
        path: '/people',
        builder: (context, state) => const PeopleSearchPage(),
      ),
      GoRoute(
        path: '/people/:id/library',
        builder: (context, state) => _viewerPage(
          context,
          PersonLibraryPage(id: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/people/:id',
        builder: (context, state) =>
            _viewerPage(context, PersonPage(id: state.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/people/:id/insights',
        builder: (context, state) =>
            _viewerPage(context, InsightsPage(id: state.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/people/:id/:list',
        builder: (context, state) => RelationshipPage(
          id: state.pathParameters['id'] == 'me'
              ? _account.state.userId ?? ''
              : state.pathParameters['id']!,
          kind: state.pathParameters['list']!,
        ),
      ),
      GoRoute(
        path: '/blocked-people',
        builder: (context, state) =>
            RelationshipPage(id: _account.state.userId ?? '', kind: 'blocked'),
      ),
      GoRoute(
        path: '/reviews/:id',
        builder: (context, state) => _viewerPage(
          context,
          ReviewDetailPage(id: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/review-list',
        builder: (context, state) => ReviewListPage(
          titleId: state.uri.queryParameters['title'],
          seasonId: state.uri.queryParameters['season'],
          author: state.uri.queryParameters['author'],
        ),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => BlocProvider(
          create: (context) => CatalogCubit(_catalog),
          child: const CatalogResultsPage(),
        ),
      ),
      GoRoute(
        path: '/trending/:kind',
        builder: (context, state) {
          final kind = _kind(state.pathParameters['kind']);
          if (kind == null) return const _UnavailableRoute();
          final shelf =
              BrowseShelf.values
                  .where(
                    (value) => value.name == state.uri.queryParameters['shelf'],
                  )
                  .firstOrNull ??
              BrowseShelf.trending;
          final genre = int.tryParse(state.uri.queryParameters['genre'] ?? '');
          return BlocProvider(
            create: (context) =>
                CatalogCubit(_catalog, kind: kind, shelf: shelf, genre: genre)
                  ..load(),
            child: CatalogResultsPage(kind: kind, shelf: shelf),
          );
        },
      ),
      GoRoute(path: '/genres', builder: (context, state) => const GenrePage()),
      GoRoute(
        path: '/credits/:id',
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          return id == null || id <= 0
              ? const _UnavailableRoute()
              : FilmographyPage(id: id);
        },
      ),
      GoRoute(
        path: '/shared-title/:id',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return _shareId.hasMatch(id)
              ? TitleDetailPage(titleId: id, key: ValueKey(id))
              : const _UnavailableRoute();
        },
      ),
      GoRoute(
        path: '/titles/:kind/:id',
        builder: (context, state) {
          final kind = _kind(state.pathParameters['kind']);
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          return kind == null || id == null || id <= 0
              ? const _UnavailableRoute()
              : TitleDetailPage(
                  kind: kind,
                  tmdbId: id,
                  key: ValueKey((kind, id)),
                );
        },
      ),
    ],
    errorBuilder: (context, state) => const _UnavailableRoute(),
  );

  MediaKind? _kind(String? value) => switch (value) {
    'movie' => MediaKind.movie,
    'show' => MediaKind.show,
    _ => null,
  };

  static final _shareId = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    caseSensitive: false,
  );

  Widget _viewerPage(BuildContext context, Widget page) =>
      BlocBuilder<AccountCubit, Account>(
        buildWhen: (before, after) =>
            before.userId != after.userId || before.phase != after.phase,
        builder: (context, account) => KeyedSubtree(
          key: ValueKey((account.userId, account.phase)),
          child: page,
        ),
      );

  void _openLink(Uri link) {
    if (!mounted ||
        link.scheme != 'com.taspa.taspa' ||
        link.host != 'share' ||
        link.pathSegments.length != 2) {
      return;
    }
    final [kind, id] = link.pathSegments;
    final tmdb = RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(id);
    if (!tmdb && !_shareId.hasMatch(id)) return;
    final target = switch (kind) {
      'm' when tmdb => '/titles/movie/$id',
      's' when tmdb => '/titles/show/$id',
      'title' when !tmdb => '/shared-title/$id',
      'review' when !tmdb => '/reviews/$id',
      _ => null,
    };
    if (target != null && _router.state.uri.path != target) {
      _router.push(target);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _syncLibrary(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_push.attach(_openNotice));
      _syncLibrary();
      _links = AppLinks().uriLinkStream.listen(
        _openLink,
        onError: (Object _) {},
      );
    });
  }

  void _openNotice(String id) {
    if (!mounted) return;
    if (_account.state.phase != AccountPhase.ready) {
      _pendingNotice = id;
      return;
    }
    _pendingNotice = null;
    final location = Uri(
      path: '/notifications',
      queryParameters: {'notice': id},
    ).toString();
    if (_router.state.uri.path == '/notifications') {
      _router.replace(location);
    } else {
      _router.push(location);
    }
  }

  void _refreshPush() {
    if (_account.state.phase == AccountPhase.ready) {
      unawaited(_push.refreshBinding().catchError((Object _) {}));
    }
  }

  void _syncLibrary() {
    final state = _account.state;
    if (state.phase == AccountPhase.ready && state.userId != null) {
      unawaited(_library.sync(state.userId!).catchError((Object _) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPush();
      _syncLibrary();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_push.dispose());
    unawaited(_links?.cancel());
    _syncTimer?.cancel();
    unawaited(_library.dispose());
    _router.dispose();
    _account.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiRepositoryProvider(
    providers: [
      RepositoryProvider.value(value: _offline),
      RepositoryProvider.value(value: _catalog),
      RepositoryProvider.value(value: _library),
      RepositoryProvider.value(value: _inbox),
      RepositoryProvider.value(value: _push),
      RepositoryProvider.value(value: _social),
    ],
    child: BlocProvider.value(
      value: _account,
      child: BlocListener<AccountCubit, Account>(
        listenWhen: (previous, current) =>
            previous.phase != current.phase ||
            previous.userId != current.userId,
        listener: (context, state) {
          final previous = _cacheOwner;
          if (state.userId != previous) {
            _cacheOwner = state.userId;
            if (previous != null) {
              unawaited(
                _offline.forgetCache(previous).catchError((Object _) {}),
              );
            }
          }
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          if (state.phase == AccountPhase.recovery &&
              _router.state.uri.path != '/account') {
            _router.push('/account', extra: '/profile');
          }
          if (state.phase == AccountPhase.ready) {
            _refreshPush();
            _syncLibrary();
            if (_pendingNotice case final id?) _openNotice(id);
          }
        },
        child: MaterialApp.router(
          title: 'Taspa',
          debugShowCheckedModeBanner: false,
          theme: taspaTheme(),
          routerConfig: _router,
        ),
      ),
    ),
  );
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.shell});

  final StatefulNavigationShell shell;

  static const _labels = ['Discover', 'Library', 'Feed', 'Profile'];

  @override
  Widget build(BuildContext context) {
    final tab = shell.currentIndex;
    return Scaffold(
      appBar: AppBar(
        title: tab == 0
            ? SvgPicture.asset(
                'assets/brand/wordmark_ivory.svg',
                width: 96,
                semanticsLabel: 'Taspa',
              )
            : Text(_labels[tab]),
        actions: [
          if (tab == 2)
            IconButton(
              tooltip: 'Find people',
              onPressed: () => context.push('/people'),
              icon: const Icon(PhosphorIconsRegular.userPlus),
            ),
          if (tab == 3)
            IconButton(
              tooltip: 'Notifications',
              onPressed: () => context.push('/notifications'),
              icon: const Icon(PhosphorIconsRegular.bell),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(top: false, bottom: false, child: shell),
      bottomNavigationBar: _TabBar(
        current: tab,
        onTab: (index) => shell.goBranch(index, initialLocation: index == tab),
        onAdd: () => showSearchSheet(context),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.current,
    required this.onTab,
    required this.onAdd,
  });

  final int current;
  final ValueChanged<int> onTab;
  final VoidCallback onAdd;

  static const _tabs = [
    (PhosphorIconsRegular.compass, PhosphorIconsFill.compass, 'Discover'),
    (PhosphorIconsRegular.filmStrip, PhosphorIconsFill.filmStrip, 'Library'),
    (PhosphorIconsRegular.lightning, PhosphorIconsFill.lightning, 'Feed'),
    (PhosphorIconsRegular.user, PhosphorIconsFill.user, 'Profile'),
  ];

  Widget _tab(int index) {
    final (icon, selectedIcon, label) = _tabs[index];
    final selected = index == current;
    final color = selected ? inkColor : mutedColor;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: InkResponse(
          onTap: () => onTab(index),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          child: SizedBox(
            height: 64,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 24,
                  color: selected ? coralColor : color,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: surfaceColor,
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    child: SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 4),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            _tab(0),
            _tab(1),
            Expanded(
              child: Center(
                child: Semantics(
                  button: true,
                  label: 'Search and add a title',
                  excludeSemantics: true,
                  child: Material(
                    color: coralColor,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: onAdd,
                      customBorder: const CircleBorder(),
                      splashFactory: NoSplash.splashFactory,
                      highlightColor: Colors.transparent,
                      child: const SizedBox(
                        width: 52,
                        height: 52,
                        child: Icon(
                          PhosphorIconsBold.plus,
                          color: onCoralColor,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _tab(2),
            _tab(3),
          ],
        ),
      ),
    ),
  );
}

class _HelpPage extends StatelessWidget {
  const _HelpPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('About Taspa')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Your film and TV diary',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        for (final (icon, text) in const [
          (
            PhosphorIconsRegular.checkCircle,
            'Log movies and rewatches with or without a date.',
          ),
          (
            PhosphorIconsRegular.bookmarkSimple,
            'Save titles to Want for later.',
          ),
          (
            PhosphorIconsRegular.playCircle,
            'Continue Watching shows the next episode — one tap to mark it.',
          ),
          (
            PhosphorIconsRegular.users,
            'Follow friends. You choose who sees your library, ratings and reviews.',
          ),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: coralColor),
                const SizedBox(width: 16),
                Expanded(child: Text(text)),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(PhosphorIconsRegular.userGear),
                title: const Text('Account and sign-in'),
                trailing: const Icon(PhosphorIconsRegular.caretRight),
                onTap: () => context.push('/account'),
              ),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.bell),
                title: const Text('Notification settings'),
                trailing: const Icon(PhosphorIconsRegular.caretRight),
                onTap: () => context.push('/notification-settings'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Catalog data and imagery from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class _UnavailableRoute extends StatelessWidget {
  const _UnavailableRoute();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: Center(
      child: TextButton(
        onPressed: () => context.go('/discover'),
        child: const Text('Back to Taspa'),
      ),
    ),
  );
}
