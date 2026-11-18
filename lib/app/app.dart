import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
                builder: (context, state) => const LibraryPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/following',
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
        builder: (context, state) => _viewerPage(context,
            PersonLibraryPage(id: state.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/people/:id',
        builder: (context, state) => _viewerPage(context,
            PersonPage(id: state.pathParameters['id']!)),
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
        builder: (context, state) => _viewerPage(context,
            ReviewDetailPage(id: state.pathParameters['id']!)),
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
          final shelf = BrowseShelf.values.where((value) => value.name == state.uri.queryParameters['shelf']).firstOrNull
              ?? BrowseShelf.trending;
          final genre = int.tryParse(state.uri.queryParameters['genre'] ?? '');
          return BlocProvider(
            create: (context) => CatalogCubit(_catalog, kind: kind, shelf: shelf, genre: genre)..load(),
            child: CatalogResultsPage(kind: kind, shelf: shelf),
          );
        },
      ),
      GoRoute(path: '/genres', builder: (context,state) => const GenrePage()),
      GoRoute(path: '/credits/:id', builder: (context,state) {
        final id = int.tryParse(state.pathParameters['id'] ?? '');
        return id == null || id <= 0 ? const _UnavailableRoute() : FilmographyPage(id: id);
      }),
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

  static final _shareId = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$', caseSensitive: false);

  Widget _viewerPage(BuildContext context, Widget page) => BlocBuilder<AccountCubit, Account>(
    buildWhen: (before, after) => before.userId != after.userId || before.phase != after.phase,
    builder: (context, account) => KeyedSubtree(key: ValueKey((account.userId, account.phase)), child: page),
  );

  void _openLink(Uri link) {
    if (!mounted || link.scheme != 'com.taspa.taspa' || link.host != 'share' || link.pathSegments.length != 2) return;
    final [kind, id] = link.pathSegments;
    if (!_shareId.hasMatch(id)) return;
    final target = switch (kind) {'title' => '/shared-title/$id', 'review' => '/reviews/$id', _ => null};
    if (target != null && _router.state.uri.path != target) _router.push(target);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) => _syncLibrary());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_push.attach(_openNotice));
      _syncLibrary();
      _links = AppLinks().uriLinkStream.listen(_openLink, onError: (Object _) {});
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
            if (previous != null) unawaited(_offline.forgetCache(previous).catchError((Object _) {}));
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

  static const _labels = ['Discover', 'Library', 'Following', 'Profile'];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: shell.currentIndex == 0
          ? SvgPicture.asset(
              'assets/brand/wordmark_ivory.svg',
              width: 96,
              semanticsLabel: 'Taspa',
            )
          : Text(_labels[shell.currentIndex]),
      actions: [
        if (shell.currentIndex != 1)
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => context.push('/notifications'),
            icon: const Icon(Icons.notifications_none),
          ),
        if (shell.currentIndex == 2)
          IconButton(
            tooltip: 'Find people',
            onPressed: () => context.push('/people'),
            icon: const Icon(Icons.person_add_alt),
          ),
        if (shell.currentIndex == 1)
          IconButton(
            tooltip: 'Search',
            onPressed: () => context.push('/search'),
            icon: const Icon(Icons.search),
          ),
        if (shell.currentIndex == 0)
          IconButton(
            tooltip: 'About Taspa',
            onPressed: () => context.push('/help'),
            icon: const Icon(Icons.info_outline),
          ),
      ],
    ),
    body: SafeArea(top: false, bottom: false, child: shell),
    bottomNavigationBar: NavigationBar(
      selectedIndex: shell.currentIndex,
      onDestinationSelected: (index) =>
          shell.goBranch(index, initialLocation: index == shell.currentIndex),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: 'Discover',
        ),
        NavigationDestination(
          icon: Icon(Icons.video_library_outlined),
          selectedIcon: Icon(Icons.video_library),
          label: 'Library',
        ),
        NavigationDestination(
          icon: Icon(Icons.people_outline),
          selectedIcon: Icon(Icons.people),
          label: 'Following',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
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
        Text('Your film and TV diary', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        const Text('Log movies and rewatches, save things to Wanted, and find your next unwatched episode in Continue Watching.'),
        const SizedBox(height: 16),
        const Text('Following shows activity from people you follow. You choose who can see your library, ratings and reviews.'),
        TextButton(onPressed: () => context.push('/account'), child: const Text('Account and sign-in help')),
        TextButton(onPressed: () => context.push('/notification-settings'), child: const Text('Notification settings')),
        const SizedBox(height: 24),
        const Text('Catalog data and imagery from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.'),
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
        child: const Text('Back to Discover'),
      ),
    ),
  );
}
