import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../social/presentation/reviews.dart';
import '../data/catalog_repository.dart';
import 'artwork.dart';
import 'catalog_cubit.dart';

class DiscoverPage extends StatelessWidget {
  const DiscoverPage({super.key});

  @override
  Widget build(BuildContext context) {
    final shelves = [for (final shelf in BrowseShelf.values)
      for (final kind in MediaKind.values) (shelf,kind)];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: shelves.length + 1,
      itemBuilder: (context,index) {
        if (index == 0) {
          return Padding(
          padding: const EdgeInsets.fromLTRB(16,8,16,24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _SearchShortcut(),
            TextButton(onPressed: () => context.push('/genres'), child: const Text('Browse genres')),
            const FollowedRecommendations(),
          ]),
          );
        }
        final (shelf,kind) = shelves[index - 1];
        return Padding(padding: const EdgeInsets.only(bottom: 32), child: BlocProvider(
          create: (context) => CatalogCubit(context.read<CatalogRepository>(), kind: kind, shelf: shelf)..load(),
          child: _TrendingShelf(kind, shelf),
        ));
      },
    );
  }
}

String catalogHeading(MediaKind kind, BrowseShelf shelf) => '${switch (shelf) {
  BrowseShelf.trending => 'Trending', BrowseShelf.popular => 'Popular',
  BrowseShelf.recent => 'New', BrowseShelf.upcoming => 'Upcoming',
}} ${kind == MediaKind.movie ? 'Movies' : 'Shows'}';

class _SearchShortcut extends StatelessWidget {
  const _SearchShortcut();

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () => context.push('/search'),
    icon: const Icon(Icons.search),
    label: const Align(
      alignment: Alignment.centerLeft,
      child: Text('Search titles, credits and people'),
    ),
  );
}

class _TrendingShelf extends StatelessWidget {
  const _TrendingShelf(this.kind, this.shelf);
  final MediaKind kind;
  final BrowseShelf shelf;

  @override
  Widget build(BuildContext context) {
    final title = catalogHeading(kind, shelf);
    final cubit = context.read<CatalogCubit>();
    final state = context.watch<CatalogCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(
                  onPressed: () => context.push('/trending/${kind.name}?shelf=${shelf.name}'),
                child: const Text('See all'),
              ),
            ],
          ),
        ),
        if (state.page?.stale == true)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Showing saved results'),
          ),
        if (state.page case final page?)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in page.items)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SizedBox(width: 96, child: _Poster(item)),
                    ),
                ],
              ),
            ),
          )
        else if (state.loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        if (state.failed)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _CatalogRetry(onRetry: cubit.load),
          ),
      ],
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster(this.title);
  final CatalogTitle title;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => context.push(title.location),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(aspectRatio: 2 / 3, child: Artwork(title.poster)),
        const SizedBox(height: 4),
        Text(title.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        Text(title.caption, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _CatalogRetry extends StatelessWidget {
  const _CatalogRetry({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('The catalog is temporarily unavailable.'),
      TextButton(onPressed: onRetry, child: const Text('Retry')),
    ],
  );
}

class CatalogResultsPage extends StatefulWidget {
  const CatalogResultsPage({super.key, this.kind, this.shelf = BrowseShelf.trending});
  final MediaKind? kind;
  final BrowseShelf shelf;

  @override
  State<CatalogResultsPage> createState() => _CatalogResultsPageState();
}

class _CatalogResultsPageState extends State<CatalogResultsPage> {
  Timer? _debounce;
  String? _query;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CatalogCubit>().state;
    final cubit = context.read<CatalogCubit>();
    final isSearch = widget.kind == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isSearch
              ? 'Search'
              : catalogHeading(widget.kind!, widget.shelf),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (isSearch)
              TextField(
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search titles and credits',
                ),
                onChanged: (value) {
                  _debounce?.cancel();
                  final query = value.trim();
                  _query = query.length < 2 ? null : query;
                  cubit.clear();
                  if (_query != null) {
                    _debounce = Timer(
                      const Duration(milliseconds: 360),
                      () => cubit.load(query: query),
                    );
                  }
                },
              ),
            if (isSearch)
              TextButton.icon(onPressed: () => context.push('/people'), icon: const Icon(Icons.person_search),
                label: const Text('Search Taspa users')),
            if (state.loading) const LinearProgressIndicator(),
            if (state.failed)
              _CatalogRetry(onRetry: () => cubit.load(query: _query)),
            if (state.page case final page?) ...[
              if (page.stale) const Text('Showing saved results'),
              if (page.items.isEmpty && page.people.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text('No matching titles or people.'),
                ),
              for (final kind in MediaKind.values)
                if (page.items.any((item) => item.kind == kind)) ...[
                  if (isSearch) Text(kind == MediaKind.movie ? 'Movies' : 'Shows', style: Theme.of(context).textTheme.titleLarge),
                  for (final item in page.items.where((item) => item.kind == kind)) CatalogTitleTile(item),
                ],
              if (page.people.isNotEmpty)
                Text('Cast and crew', style: Theme.of(context).textTheme.titleLarge),
              for (final person in page.people)
                CatalogPersonTile(person),
              if (page.nextPage != null)
                OutlinedButton(
                  onPressed: state.loading
                      ? null
                      : () => cubit.load(query: _query, more: true),
                  child: const Text('Load more'),
                ),
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
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 8),
    leading: SizedBox(width: 48, height: 72, child: Artwork(title.poster)),
    title: Text(title.name), subtitle: Text(title.caption),
    onTap: () => context.push(title.location),
  );
}

class CatalogPersonTile extends StatelessWidget {
  const CatalogPersonTile(this.person, {super.key});
  final CatalogPerson person;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 8),
    leading: SizedBox(width: 48, height: 72, child: Artwork(person.portrait)),
    title: Text(person.name), subtitle: person.role == null ? null : Text(person.role!),
    onTap: () => context.push('/credits/${person.id}'),
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
    appBar: AppBar(title: const Text('Filmography')),
    body: FutureBuilder(future: _result, builder: (context,snapshot) {
      if (snapshot.hasError) {
        return Center(child: TextButton(onPressed: () => setState(() => _result = _load()),
          child: const Text('Could not load credits. Retry')));
      }
      final result = snapshot.data;
      if (result == null) return const Center(child: CircularProgressIndicator());
      return ListView(padding: const EdgeInsets.all(16), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 72, height: 108, child: Artwork(result.identity.portrait)),
          const SizedBox(width: 16),
          Expanded(child: Text(result.identity.name, style: Theme.of(context).textTheme.displaySmall)),
        ]),
        const SizedBox(height: 24),
        if (result.credits.isEmpty) const Text('No catalog credits found.'),
        for (final title in result.credits) CatalogTitleTile(title),
      ]);
    }),
  );
}

class GenrePage extends StatelessWidget {
  const GenrePage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Genres')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      for (final (id, label) in const [(18,'Drama'),(35,'Comedy'),(80,'Crime'),(16,'Animation'),(9648,'Mystery')])
        ListTile(title: Text(label), trailing: Wrap(children: [
          TextButton(onPressed: () => context.push('/trending/movie?shelf=popular&genre=$id'), child: const Text('Movies')),
          TextButton(onPressed: () => context.push('/trending/show?shelf=popular&genre=$id'), child: const Text('Shows')),
        ])),
    ]),
  );
}
