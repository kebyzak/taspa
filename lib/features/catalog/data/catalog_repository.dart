import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend_config.dart';
import '../../../core/offline_store.dart';

enum MediaKind { movie, show }

enum BrowseShelf { trending, popular, recent, upcoming }

typedef CatalogPerson = ({int id, String name, String? role, String? portrait});

CatalogPerson personFromMap(Map<String, dynamic> row) => (
  id: row['tmdb_id'] as int,
  name: row['name'] as String,
  role: (row['role'] ?? row['department']) as String?,
  portrait: row['portrait'] as String?,
);

class CatalogTitle {
  const CatalogTitle({
    required this.tmdbId,
    required this.kind,
    required this.name,
    this.id,
    this.originalTitle,
    this.overview,
    this.poster,
    this.backdrop,
    this.releaseDay,
    this.runtime,
    this.genres = const [],
    this.details = const {},
    this.releaseStatus,
  });

  factory CatalogTitle.fromMap(Map<String, dynamic> row) => CatalogTitle(
    id: row['id'] as String?,
    tmdbId: row['tmdb_id'] as int,
    kind: MediaKind.values.byName(row['kind'] as String),
    name: row['display_title'] as String,
    originalTitle: row['original_title'] as String?,
    overview: row['overview'] as String?,
    poster: row['poster_path'] as String?,
    backdrop: row['backdrop_path'] as String?,
    releaseDay: DateTime.tryParse(row['first_release_day'] as String? ?? ''),
    runtime: row['runtime_minutes'] as int?,
    genres: List<String>.from(
      (row['genres'] ?? row['details']?['genres']) as List? ?? const [],
    ),
    details: row['details'] as Map<String, dynamic>? ?? const {},
    releaseStatus: row['source_release_status'] as String?,
  );

  final String? id;
  final int tmdbId;
  final MediaKind kind;
  final String name;
  final String? originalTitle;
  final String? overview;
  final String? poster;
  final String? backdrop;
  final DateTime? releaseDay;
  final int? runtime;
  final List<String> genres;
  final Map<String, dynamic> details;
  final String? releaseStatus;

  String get caption => [
    kind == MediaKind.movie ? 'Movie' : 'TV show',
    if (releaseDay case final day?) day.year.toString(),
  ].join(' · ');

  String get location => '/titles/${kind.name}/$tmdbId';

  Map<String, dynamic> toMap() => {
    'id': id,
    'kind': kind.name,
    'tmdb_id': tmdbId,
    'display_title': name,
    'original_title': originalTitle,
    'overview': overview,
    'poster_path': poster,
    'backdrop_path': backdrop,
    'first_release_day': releaseDay?.toIso8601String(),
    'runtime_minutes': runtime,
    'genres': genres,
    'details': details,
    'source_release_status': releaseStatus,
  };
}

typedef CatalogPage = ({
  List<CatalogTitle> items,
  List<CatalogPerson> people,
  int? nextPage,
  bool stale,
});
typedef CatalogSeason = ({String id, int number, String title, bool loaded});
typedef CatalogEpisode = ({
  String id,
  int number,
  String title,
  bool released,
  String? releaseDay,
  bool watched,
  String? watchedOn,
  int revision,
});

class CatalogFailure implements Exception {
  const CatalogFailure(this.status);

  final int status;
}

class CatalogRepository {
  CatalogRepository(this.client, this.store);

  final SupabaseClient client;
  final OfflineStore store;

  static const _fresh = {
    'trending': Duration(hours: 2),
    'search': Duration(minutes: 30),
    'hydrate': Duration(hours: 6),
    'person': Duration(hours: 24),
  };

  Future<Map<String, dynamic>> _call(Map<String, Object> input) {
    if (input['operation'] == 'hydrate_season') return _request(input);
    return store.cached(
      '',
      'catalog:${jsonEncode(input)}',
      () => _request(input),
      canUseCache: (error) =>
          transientReadFailure(error) ||
          (error is CatalogFailure &&
              (error.status == 429 || error.status >= 500)),
      fallback: (saved) => {...saved as Map<String, dynamic>, 'stale': true},
      maxAge: _fresh[input['operation']],
      reuse: (saved) => saved as Map<String, dynamic>,
    );
  }

  Future<List<CatalogTitle>> forYou({bool refresh = false}) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) return [];
    if (refresh) {
      await store.remove(owner, 'cache', 'for_you').catchError((Object _) {});
    }
    final rows = await store.cached(
      owner,
      'for_you',
      () async => await client.schema('api').rpc('for_you') as List,
      fallback: (saved) => saved as List,
      maxAge: const Duration(minutes: 30),
      reuse: (saved) => saved as List,
    );
    return [
      for (final row in rows.cast<Map<String, dynamic>>())
        CatalogTitle.fromMap(row),
    ];
  }

  Future<Map<String, dynamic>> _request(Map<String, Object> input) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _send(input);
      } on CatalogFailure catch (error) {
        if (attempt == 2 || error.status != 429 && error.status < 500) rethrow;
      }
      await Future<void>.delayed(Duration(seconds: 2 << attempt));
    }
  }

  Future<Map<String, dynamic>> _send(Map<String, Object> input) async {
    final token = client.auth.currentSession?.accessToken;
    final response = await http
        .post(
          Uri.parse('$backendUrl/functions/v1/catalog'),
          headers: {
            'apikey': publishableKey,
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode(input),
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) throw CatalogFailure(response.statusCode);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<CatalogPage> list({
    MediaKind? kind,
    String? query,
    int page = 1,
    BrowseShelf shelf = BrowseShelf.trending,
    int? genre,
  }) async {
    final json = await _call({
      'operation': query == null ? 'trending' : 'search',
      if (kind != null) 'kind': kind.name,
      'query': ?query,
      'page': page,
      if (query == null)
        'shelf': shelf == BrowseShelf.recent ? 'new' : shelf.name,
      'genre': ?genre,
    });
    final data = json['data'] as Map<String, dynamic>;
    return (
      items: (data['items'] as List)
          .map((item) => CatalogTitle.fromMap(item as Map<String, dynamic>))
          .toList(),
      nextPage: data['next_page'] as int?,
      people: (data['people'] as List? ?? const [])
          .map((row) => personFromMap(row as Map<String, dynamic>))
          .toList(),
      stale: json['stale'] == true,
    );
  }

  Future<CatalogTitle> detail(MediaKind kind, int tmdbId) async {
    try {
      final json = await _call({
        'operation': 'hydrate',
        'kind': kind.name,
        'tmdb_id': tmdbId,
      });
      return CatalogTitle.fromMap(json['data'] as Map<String, dynamic>);
    } on Exception catch (error) {
      if (error is CatalogFailure &&
          (error.status == 404 || error.status == 401)) {
        rethrow;
      }
      final existing = await client
          .schema('api')
          .from('titles')
          .select()
          .eq('kind', kind.name)
          .eq('tmdb_id', tmdbId)
          .maybeSingle();
      if (existing == null) rethrow;
      try {
        final metadata = await client
            .schema('api')
            .rpc('title_metadata', params: {'title': existing['id']});
        if (metadata != null) existing['details'] = metadata;
      } on Exception {
        // Core normalized metadata is still useful when extras are unavailable.
      }
      return CatalogTitle.fromMap(existing);
    }
  }

  Future<CatalogTitle> sharedTitle(String id) async {
    final row = await client
        .schema('api')
        .from('titles')
        .select('kind,tmdb_id')
        .eq('id', id)
        .single();
    return detail(
      MediaKind.values.byName(row['kind'] as String),
      row['tmdb_id'] as int,
    );
  }

  Future<({CatalogPerson identity, List<CatalogTitle> credits})> person(
    int id,
  ) async {
    final result = await _call({'operation': 'person', 'tmdb_id': id});
    final row = result['data'] as Map<String, dynamic>;
    return (
      identity: personFromMap(row),
      credits: (row['items'] as List)
          .map((item) => CatalogTitle.fromMap(item as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<List<CatalogSeason>> seasons(String showId) async {
    final rows = await store.cached(
      '',
      'seasons:$showId',
      () async => await client
          .schema('api')
          .from('seasons')
          .select('id,season_number,display_title,loaded_at')
          .eq('show_id', showId)
          .order('season_number', ascending: true),
      fallback: (saved) => (saved as List).cast<Map<String, dynamic>>(),
    );
    return rows
        .map(
          (row) => (
            id: row['id'] as String,
            number: row['season_number'] as int,
            title: row['display_title'] as String,
            loaded: row['loaded_at'] != null,
          ),
        )
        .toList();
  }

  /// Released and watched episode counts per season id, for the signed-in user.
  Future<Map<String, ({int released, int watched})>> seasonProgress(
    String showId,
  ) async {
    final owner = client.auth.currentUser?.id ?? '';
    if (owner.isEmpty) return const {};
    final rows = await store.cached(
      owner,
      'season_progress:$showId',
      () async =>
          await client
                  .schema('api')
                  .rpc('season_progress', params: {'title_id': showId})
              as List,
      fallback: (saved) => saved as List,
    );
    return {
      for (final row in rows.cast<Map<String, dynamic>>())
        row['season_id'] as String: (
          released: row['released'] as int,
          watched: row['watched'] as int,
        ),
    };
  }

  Future<void> hydrateSeason(int tmdbId, int seasonNumber) async {
    await _call({
      'operation': 'hydrate_season',
      'tmdb_id': tmdbId,
      'season_number': seasonNumber,
    });
  }

  Future<List<CatalogEpisode>> episodes(String showId, String seasonId) async {
    final owner = client.auth.currentUser?.id ?? '';
    final result = await store.cached(
      owner,
      'episodes:$showId:$seasonId',
      () async {
        final response =
            await client
                    .schema('api')
                    .rpc(
                      'show_episode_page',
                      params: {'title_id': showId, 'selected_season': seasonId},
                    )
                as Map<String, dynamic>;
        if ((client.auth.currentUser?.id ?? '') != owner) {
          throw const CatalogFailure(401);
        }
        return response;
      },
      fallback: (saved) => saved as Map<String, dynamic>,
    );
    final pending = owner.isEmpty
        ? null
        : await store.read(owner, 'outbox', showId) as Map<String, dynamic>?;
    final payload = pending?['sync'] == 'conflict'
        ? null
        : pending?['payload'] as Map<String, dynamic>?;
    final batch = (payload?['episodes'] as List? ?? const [])
        .map((item) => item['id'])
        .toSet();
    return (result['episodes'] as List).map((row) {
      final individual =
          row['id'] == payload?['episode_id'] &&
          pending?['action'] != 'apply_show_batch';
      final inBatch = batch.contains(row['id']);
      final watching = individual
          ? (payload?['watched'] as bool?)
          : inBatch
          ? !{
              'remove_show',
              'mark_season_unwatched',
            }.contains(payload?['scope'])
          : null;
      return (
        id: row['id'] as String,
        number: row['number'] as int,
        title: row['title'] as String,
        released: row['released'] as bool,
        releaseDay: row['release_day'] as String?,
        watched: watching ?? row['watched'] as bool,
        watchedOn: individual || inBatch
            ? (payload?['watched_on'] as String? ??
                  (watching == true ? _today() : null))
            : (row['watched_on'] ?? row['marked_on']) as String?,
        revision: row['revision'] as int,
      );
    }).toList();
  }
}

String _today() => DateTime.now().toIso8601String().split('T').first;
