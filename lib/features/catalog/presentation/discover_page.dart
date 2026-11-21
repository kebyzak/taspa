import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../auth/auth_cubit.dart';
import '../../library/data/library_repository.dart';
import '../../library/presentation/tracking_cubit.dart';
import '../data/catalog_repository.dart';
import 'artwork.dart';
import 'catalog_cubit.dart';

String catalogHeading(MediaKind kind, BrowseShelf shelf) =>
    '${switch (shelf) {
      BrowseShelf.trending => 'Trending',
      BrowseShelf.popular => 'Popular',
      BrowseShelf.recent => 'New',
      BrowseShelf.upcoming => 'Upcoming',
    }} ${kind == MediaKind.movie ? 'Movies' : 'Shows'}';

class DiscoverPage extends StatelessWidget {
  const DiscoverPage({super.key});

  static const _shelves = [
    (BrowseShelf.trending, MediaKind.movie),
    (BrowseShelf.trending, MediaKind.show),
    (BrowseShelf.upcoming, MediaKind.movie),
    (BrowseShelf.recent, MediaKind.show),
    (BrowseShelf.popular, MediaKind.movie),
    (BrowseShelf.popular, MediaKind.show),
    (BrowseShelf.recent, MediaKind.movie),
    (BrowseShelf.upcoming, MediaKind.show),
  ];

  @override
  Widget build(BuildContext context) {
    final ready =
        context.watch<AccountCubit>().state.phase == AccountPhase.ready;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 32),
      itemCount: _shelves.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Semantics(
                  button: true,
                  label: 'Search titles, credits and people',
                  excludeSemantics: true,
                  child: Material(
                    color: surfaceColor,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: () => showSearchSheet(context),
                      borderRadius: BorderRadius.circular(12),
                      child: const SizedBox(
                        height: 52,
                        child: Row(
                          children: [
                            SizedBox(width: 16),
                            Icon(
                              PhosphorIconsRegular.magnifyingGlass,
                              color: mutedColor,
                            ),
                            SizedBox(width: 12),
                            Text(
                              'Movies, shows, people',
                              style: TextStyle(color: mutedColor),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (ready) const _ForYou(),
              const SizedBox(height: 24),
            ],
          );
        }
        final (shelf, kind) = _shelves[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: BlocProvider(
            create: (context) => CatalogCubit(
              context.read<CatalogRepository>(),
              kind: kind,
              shelf: shelf,
            )..load(),
            child: _TrendingShelf(kind, shelf),
          ),
        );
      },
    );
  }
}

class _ForYou extends StatefulWidget {
  const _ForYou();

  @override
  State<_ForYou> createState() => _ForYouState();
}

class _ForYouState extends State<_ForYou> {
  late Future<List<CatalogTitle>> _picks = context
      .read<CatalogRepository>()
      .forYou();
  late final StreamSubscription<void> _changes = context
      .read<LibraryRepository>()
      .changes
      .listen((_) {
        if (mounted) {
          setState(() {
            _picks = context.read<CatalogRepository>().forYou(refresh: true);
          });
        }
      });

  @override
  void initState() {
    super.initState();
    _changes;
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _picks,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const SizedBox.shrink();
      final picks = snapshot.data;
      if (picks != null && picks.isEmpty) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: const Icon(
                PhosphorIconsRegular.sparkle,
                color: coralColor,
              ),
              title: const Text('Picks for you'),
              subtitle: const Text(
                'Mark a few titles watched and personal picks show up here.',
              ),
              onTap: () => showSearchSheet(context),
            ),
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('For you'),
          Shelf(
            itemWidth: 136,
            children: picks == null
                ? null
                : [
                    for (final item in picks)
                      PosterCard(
                        poster: item.poster,
                        title: item.name,
                        caption: item.caption,
                        own: (item.kind.name, item.tmdbId),
                        onTap: () => context.push(item.location),
                      ),
                  ],
          ),
        ],
      );
    },
  );
}

class _TrendingShelf extends StatelessWidget {
  const _TrendingShelf(this.kind, this.shelf);

  final MediaKind kind;
  final BrowseShelf shelf;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<CatalogCubit>();
    final state = context.watch<CatalogCubit>().state;
    final page = state.page;
    if (page != null && page.items.isEmpty && !state.loading && !state.failed) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          catalogHeading(kind, shelf),
          onMore: () =>
              context.push('/trending/${kind.name}?shelf=${shelf.name}'),
          trailing: page?.stale == true
              ? const Tooltip(
                  message: 'Showing saved results',
                  child: Icon(
                    PhosphorIconsRegular.cloudSlash,
                    size: 18,
                    color: mutedColor,
                  ),
                )
              : null,
        ),
        if (state.failed && page == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _CatalogRetry(onRetry: cubit.load),
          )
        else
          Shelf(
            children: page == null
                ? null
                : [
                    for (final item in page.items)
                      PosterCard(
                        poster: item.poster,
                        title: item.name,
                        caption: item.caption,
                        own: (item.kind.name, item.tmdbId),
                        onTap: () => context.push(item.location),
                      ),
                  ],
          ),
      ],
    );
  }
}

Future<void> showSearchSheet(BuildContext context, {String? query}) =>
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => BlocProvider(
        create: (_) => CatalogCubit(context.read<CatalogRepository>()),
        child: FractionallySizedBox(
          heightFactor: .94,
          child: _SearchSheet(router: GoRouter.of(context), query: query),
        ),
      ),
    );

class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.router, this.query});

  final GoRouter router;
  final String? query;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _field = TextEditingController();
  Timer? _debounce;
  String? _query;
  String? _error;
  final _busy = <int>{};
  final _done = <int, Set<String>>{};

  @override
  void initState() {
    super.initState();
    if (widget.query case final query?) {
      _field.text = query;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _changed(query);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _changed(String value) {
    final cubit = context.read<CatalogCubit>();
    _debounce?.cancel();
    final query = value.trim();
    setState(() {
      _query = query.length < 2 ? null : query;
      _error = null;
    });
    cubit.clear();
    if (_query != null) {
      _debounce = Timer(
        const Duration(milliseconds: 300),
        () => cubit.load(query: query),
      );
    }
  }

  void _go(String location) {
    Navigator.pop(context);
    widget.router.push(location);
  }

  Future<void> _quick(CatalogTitle item, String action) async {
    if (context.read<AccountCubit>().state.phase != AccountPhase.ready) {
      _go('/account');
      return;
    }
    if (!_busy.add(item.tmdbId)) return;
    setState(() => _error = null);
    final catalog = context.read<CatalogRepository>();
    final repo = context.read<LibraryRepository>();
    try {
      final full = item.id == null
          ? await catalog.detail(item.kind, item.tmdbId)
          : item;
      final id = full.id!;
      await repo.rememberTitle(full);
      final state = await repo.snapshot(id);
      await repo.apply(switch (action) {
        'want' => TrackingCommand(id, 'set_wanted', {
          'wanted': true,
          'wanted_revision': state.revision,
        }),
        'start' => TrackingCommand(id, 'start_show', {
          'show_revision': state.showRevision,
          'wanted_revision': state.revision,
        }),
        _ => TrackingCommand(id, 'mark_movie_watched', {
          'viewing_id': const Uuid().v4(),
          'wanted_revision': state.revision,
        }),
      });
      if (mounted) setState(() => (_done[item.tmdbId] ??= {}).add(action));
    } on Exception catch (error) {
      if (mounted) {
        setState(() => _error = '${item.name}: ${trackingMessage(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy.remove(item.tmdbId));
    }
  }

  Widget _result(CatalogTitle item) {
    final busy = _busy.contains(item.tmdbId);
    final done = _done[item.tmdbId] ?? const {};
    final movie = item.kind == MediaKind.movie;
    final upcoming =
        item.releaseDay?.isAfter(DateUtils.dateOnly(DateTime.now())) ?? false;
    final primary = movie ? 'watched' : 'start';
    return InkWell(
      onTap: () => _go(item.location),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(width: 48, height: 72, child: Artwork(item.poster)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    item.caption,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (!done.contains(primary))
              IconButton(
                tooltip: done.contains('want')
                    ? '${item.name} is in Want'
                    : 'Add ${item.name} to Want',
                onPressed: busy || done.contains('want')
                    ? null
                    : () => _quick(item, 'want'),
                icon: Icon(
                  done.contains('want')
                      ? PhosphorIconsFill.bookmarkSimple
                      : PhosphorIconsRegular.bookmarkSimple,
                  size: 20,
                  color: done.contains('want') ? coralColor : mutedColor,
                ),
              ),
            if (!upcoming && done.contains(primary))
              Semantics(
                label: movie ? 'Marked watched' : 'Tracking',
                child: const SizedBox(
                  width: 48,
                  child: Icon(
                    PhosphorIconsBold.check,
                    size: 16,
                    color: mutedColor,
                  ),
                ),
              )
            else if (!upcoming)
              IconButton.outlined(
                tooltip: movie
                    ? 'Mark ${item.name} watched'
                    : 'Start watching ${item.name}',
                onPressed: busy ? null : () => _quick(item, primary),
                style: IconButton.styleFrom(
                  minimumSize: const Size(32, 32),
                  fixedSize: const Size(32, 32),
                  padding: EdgeInsets.zero,
                  side: const BorderSide(color: coralColor),
                ),
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : Icon(
                        movie
                            ? PhosphorIconsRegular.check
                            : PhosphorIconsRegular.plus,
                        size: 12,
                        color: coralColor,
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadMarks(ShelfState state) async {
    final items = state.page?.items ?? const <CatalogTitle>[];
    try {
      final marks = await context.read<LibraryRepository>().marks(items);
      if (!mounted) return;
      setState(() {
        for (final MapEntry(:key, :value) in marks.entries) {
          (_done[key] ??= {}).addAll(value);
        }
      });
    } on Exception {
      // Marks are a hint; the quick actions still work without them.
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CatalogCubit>().state;
    final page = state.page;
    return BlocListener<CatalogCubit, ShelfState>(
      listenWhen: (before, after) =>
          after.page != null && before.page != after.page,
      listener: (context, state) => _loadMarks(state),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _field,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(PhosphorIconsRegular.magnifyingGlass),
                  hintText: 'Movies, shows, people',
                  suffixIcon: _field.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(PhosphorIconsRegular.x),
                          onPressed: () {
                            _field.clear();
                            _changed('');
                          },
                        ),
                ),
                onChanged: _changed,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 4,
              child: state.loading ? const LinearProgressIndicator() : null,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (_error case final error?)
                    InlineNotice(
                      error,
                      icon: PhosphorIconsRegular.warningCircle,
                    ),
                  if (_query == null) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        backgroundColor: pressedColor,
                        child: Icon(
                          PhosphorIconsRegular.users,
                          color: coralColor,
                        ),
                      ),
                      title: const Text('Find friends on Taspa'),
                      trailing: const Icon(PhosphorIconsRegular.caretRight),
                      onTap: () => _go('/people'),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Browse',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final kind in MediaKind.values)
                          for (final shelf in BrowseShelf.values)
                            ActionChip(
                              label: Text(catalogHeading(kind, shelf)),
                              onPressed: () => _go(
                                '/trending/${kind.name}?shelf=${shelf.name}',
                              ),
                            ),
                        ActionChip(
                          avatar: const Icon(
                            PhosphorIconsRegular.shapes,
                            size: 18,
                          ),
                          label: const Text('Genres'),
                          onPressed: () => _go('/genres'),
                        ),
                      ],
                    ),
                  ],
                  if (state.failed)
                    InlineNotice(
                      'The catalog is temporarily unavailable.',
                      icon: PhosphorIconsRegular.cloudSlash,
                      action: 'Retry',
                      onAction: () =>
                          context.read<CatalogCubit>().load(query: _query),
                    ),
                  if (page case final page? when _query != null) ...[
                    if (page.stale)
                      const InlineNotice(
                        'Showing saved results',
                        icon: PhosphorIconsRegular.cloudSlash,
                      ),
                    if (page.items.isEmpty && page.people.isEmpty)
                      const EmptyState(
                        icon: PhosphorIconsRegular.magnifyingGlass,
                        title: 'Nothing found',
                        message: 'Try another spelling or the original title.',
                      ),
                    for (final kind in MediaKind.values)
                      if (page.items.any((item) => item.kind == kind)) ...[
                        SectionHeader(
                          kind == MediaKind.movie ? 'Movies' : 'Shows',
                          padding: const EdgeInsets.only(top: 8),
                        ),
                        for (final item in page.items.where(
                          (item) => item.kind == kind,
                        ))
                          _result(item),
                      ],
                    if (page.people.isNotEmpty) ...[
                      const SectionHeader(
                        'Cast and crew',
                        padding: EdgeInsets.only(top: 8),
                      ),
                      for (final person in page.people)
                        InkWell(
                          onTap: () => _go('/credits/${person.id}'),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Artwork(
                                    person.portrait,
                                    radius: 24,
                                    icon: PhosphorIconsRegular.user,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    person.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                    if (page.nextPage != null)
                      OutlinedButton(
                        onPressed: state.loading
                            ? null
                            : () => context.read<CatalogCubit>().load(
                                query: _query,
                                more: true,
                              ),
                        child: const Text('Load more'),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogRetry extends StatelessWidget {
  const _CatalogRetry({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => InlineNotice(
    'The catalog is temporarily unavailable.',
    icon: PhosphorIconsRegular.cloudSlash,
    action: 'Retry',
    onAction: onRetry,
  );
}

class CatalogResultsPage extends StatefulWidget {
  const CatalogResultsPage({
    super.key,
    this.kind,
    this.shelf = BrowseShelf.trending,
  });

  final MediaKind? kind;
  final BrowseShelf shelf;

  @override
  State<CatalogResultsPage> createState() => _CatalogResultsPageState();
}

class _CatalogResultsPageState extends State<CatalogResultsPage> {
  Timer? _debounce;
  String? _query;
  final _field = TextEditingController();

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _changed(String value) {
    final cubit = context.read<CatalogCubit>();
    _debounce?.cancel();
    final query = value.trim();
    setState(() => _query = query.length < 2 ? null : query);
    cubit.clear();
    if (_query != null) {
      _debounce = Timer(
        const Duration(milliseconds: 360),
        () => cubit.load(query: query),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CatalogCubit>().state;
    final cubit = context.read<CatalogCubit>();
    final isSearch = widget.kind == null;
    final page = state.page;
    final more = page?.nextPage != null
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: OutlinedButton(
              onPressed: state.loading
                  ? null
                  : () => cubit.load(query: _query, more: true),
              child: const Text('Load more'),
            ),
          )
        : null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: isSearch ? 0 : 16,
        title: isSearch
            ? Padding(
                padding: const EdgeInsets.only(right: 16),
                child: TextField(
                  controller: _field,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(
                      PhosphorIconsRegular.magnifyingGlass,
                    ),
                    hintText: 'Movies, shows, people',
                    suffixIcon: _field.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(PhosphorIconsRegular.x),
                            onPressed: () {
                              _field.clear();
                              _changed('');
                            },
                          ),
                  ),
                  onChanged: _changed,
                ),
              )
            : Text(catalogHeading(widget.kind!, widget.shelf)),
        bottom: state.loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: SafeArea(
        child: !isSearch
            ? CustomScrollView(
                slivers: [
                  if (state.failed || page?.stale == true)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      sliver: SliverToBoxAdapter(
                        child: state.failed
                            ? _CatalogRetry(onRetry: () => cubit.load())
                            : const InlineNotice(
                                'Showing saved results',
                                icon: PhosphorIconsRegular.cloudSlash,
                              ),
                      ),
                    ),
                  if (page != null)
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverGrid.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 140,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 16,
                              childAspectRatio: .5,
                            ),
                        itemCount: page.items.length,
                        itemBuilder: (context, index) {
                          final item = page.items[index];
                          return PosterCard(
                            poster: item.poster,
                            title: item.name,
                            caption: item.caption,
                            own: (item.kind.name, item.tmdbId),
                            onTap: () => context.push(item.location),
                          );
                        },
                      ),
                    ),
                  if (more != null)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverToBoxAdapter(child: more),
                    ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  if (_query == null) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        backgroundColor: surfaceColor,
                        child: Icon(
                          PhosphorIconsRegular.users,
                          color: coralColor,
                        ),
                      ),
                      title: const Text('Find people on Taspa'),
                      trailing: const Icon(PhosphorIconsRegular.caretRight),
                      onTap: () => context.push('/people'),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Browse by genre',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (id, label, _) in genres)
                          ActionChip(
                            label: Text(label),
                            onPressed: () => context.push('/genres?genre=$id'),
                          ),
                      ],
                    ),
                  ],
                  if (state.failed)
                    _CatalogRetry(onRetry: () => cubit.load(query: _query)),
                  if (page case final page? when _query != null) ...[
                    if (page.stale)
                      const InlineNotice(
                        'Showing saved results',
                        icon: PhosphorIconsRegular.cloudSlash,
                      ),
                    if (page.items.isEmpty && page.people.isEmpty)
                      const EmptyState(
                        icon: PhosphorIconsRegular.magnifyingGlass,
                        title: 'Nothing found',
                        message: 'Try another spelling or the original title.',
                      ),
                    for (final kind in MediaKind.values)
                      if (page.items.any((item) => item.kind == kind)) ...[
                        SectionHeader(
                          kind == MediaKind.movie ? 'Movies' : 'Shows',
                          padding: const EdgeInsets.only(top: 8),
                        ),
                        for (final item in page.items.where(
                          (item) => item.kind == kind,
                        ))
                          CatalogTitleTile(item),
                      ],
                    if (page.people.isNotEmpty) ...[
                      const SectionHeader(
                        'Cast and crew',
                        padding: EdgeInsets.only(top: 8),
                      ),
                      for (final person in page.people)
                        CatalogPersonTile(person),
                    ],
                    ?more,
                  ],
                ],
              ),
      ),
    );
  }
}

class CatalogTitleTile extends StatelessWidget {
  const CatalogTitleTile(this.title, {super.key});

  final CatalogTitle title;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => context.push(title.location),
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 48, height: 72, child: Artwork(title.poster)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  title.caption,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class CatalogPersonTile extends StatelessWidget {
  const CatalogPersonTile(this.person, {super.key});

  final CatalogPerson person;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => context.push('/credits/${person.id}'),
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: Artwork(
              person.portrait,
              radius: 24,
              icon: PhosphorIconsRegular.user,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (person.role case final role?)
                  Text(role, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class CatalogPersonAvatar extends StatelessWidget {
  const CatalogPersonAvatar(this.person, {super.key});

  final CatalogPerson person;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => context.push('/credits/${person.id}'),
    borderRadius: BorderRadius.circular(12),
    child: Column(
      children: [
        SizedBox(
          width: 72,
          height: 72,
          child: ClipOval(
            clipBehavior: Clip.antiAliasWithSaveLayer,
            child: Artwork(
              person.portrait,
              radius: 36,
              icon: PhosphorIconsRegular.user,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          person.name,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13,
            height: 1.3,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (person.role case final role?)
          Text(
            role,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: mutedColor),
          ),
      ],
    ),
  );
}

class FilmographyPage extends StatefulWidget {
  const FilmographyPage({super.key, required this.id});

  final int id;

  @override
  State<FilmographyPage> createState() => _FilmographyPageState();
}

class _FilmographyPageState extends State<FilmographyPage> {
  late var _result = _load();

  Future<({CatalogPerson identity, List<CatalogTitle> credits})> _load() =>
      context.read<CatalogRepository>().person(widget.id);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: FutureBuilder(
      future: _result,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() {
                _result = _load();
              }),
              child: const Text('Could not load credits. Retry'),
            ),
          );
        }
        final result = snapshot.data;
        if (result == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  SizedBox(
                    width: 112,
                    height: 112,
                    child: Artwork(
                      result.identity.portrait,
                      radius: 56,
                      icon: PhosphorIconsRegular.user,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      result.identity.name,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${result.credits.length} titles',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  if (result.credits.isEmpty)
                    const Text('No catalog credits found.'),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 140,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 16,
                  childAspectRatio: .5,
                ),
                itemCount: result.credits.length,
                itemBuilder: (context, index) {
                  final title = result.credits[index];
                  return PosterCard(
                    poster: title.poster,
                    title: title.name,
                    caption: title.caption,
                    own: (title.kind.name, title.tmdbId),
                    onTap: () => context.push(title.location),
                  );
                },
              ),
            ),
          ],
        );
      },
    ),
  );
}

const genres = [
  (18, 'Drama', PhosphorIconsRegular.maskHappy),
  (35, 'Comedy', PhosphorIconsRegular.smiley),
  (80, 'Crime', PhosphorIconsRegular.detective),
  (16, 'Animation', PhosphorIconsRegular.paintBrush),
  (9648, 'Mystery', PhosphorIconsRegular.magnifyingGlass),
];

class GenrePage extends StatefulWidget {
  const GenrePage({super.key});

  @override
  State<GenrePage> createState() => _GenrePageState();
}

class _GenrePageState extends State<GenrePage> {
  MediaKind _kind = MediaKind.movie;

  @override
  Widget build(BuildContext context) {
    final picked = int.tryParse(
      GoRouterState.of(context).uri.queryParameters['genre'] ?? '',
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Genres')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<MediaKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: MediaKind.movie, label: Text('Movies')),
              ButtonSegment(value: MediaKind.show, label: Text('Shows')),
            ],
            selected: {_kind},
            onSelectionChanged: (value) => setState(() => _kind = value.first),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.6,
            children: [
              for (final (id, label, icon) in genres)
                Card(
                  color: id == picked ? selectedColor : surfaceColor,
                  child: InkWell(
                    onTap: () => context.push(
                      '/trending/${_kind.name}?shelf=popular&genre=$id',
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Icon(icon, color: coralColor),
                          Text(
                            label,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
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
