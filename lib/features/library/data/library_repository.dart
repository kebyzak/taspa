import '../../../core/offline_store.dart';

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../catalog/data/catalog_repository.dart';

enum LibrarySection { watchedMovies, watchedShows, wanted }

enum LibrarySort { activity, viewing, title, rating, release }

class TrackingState {
  const TrackingState({
    required this.wanted,
    required this.revision,
    required this.viewings,
    this.intent,
    this.status,
    this.showRevision = 0,
    this.released = 0,
    this.watched = 0,
    this.seasonsReleased = 0,
    this.seasonsCompleted = 0,
    this.coverage = false,
    this.next,
    this.upcomingDay,
    this.pendingSeason,
    this.undoSkipped = 0,
    this.syncStatus,
  });

  factory TrackingState.fromMap(Map<String, dynamic> row) => TrackingState(
    wanted: row['wanted'] as bool,
    revision: row['wanted_revision'] as int,
    viewings: row['viewing_count'] as int,
    intent: row['intent'] as String?,
    status: row['status'] as String?,
    showRevision: row['show_revision'] as int? ?? 0,
    released: row['released'] as int? ?? 0,
    watched: row['watched'] as int? ?? 0,
    seasonsReleased: row['seasons_released'] as int? ?? 0,
    seasonsCompleted: row['seasons_completed'] as int? ?? 0,
    coverage: row['coverage'] == true,
    next: switch (row['next']) {
      final Map<String, dynamic> data => (
        id: data['id'] as String,
        revision: data['revision'] as int,
        title: data['display_title'] as String,
        season: data['season_number'] as int,
        number: data['episode_number'] as int,
      ),
      _ => null,
    },
    upcomingDay: row['upcoming_day'] as String?,
    pendingSeason: row['pending_season'] as int?,
    undoSkipped: row['undo_skipped'] as int? ?? 0,
    syncStatus: row['local_sync'] as String?,
  );

  final bool wanted;
  final int revision;
  final int viewings;
  final String? intent;
  final String? status;
  final int showRevision;
  final int released;
  final int watched;
  final int seasonsReleased;
  final int seasonsCompleted;
  final bool coverage;
  final NextEpisode? next;
  final String? upcomingDay;
  final int? pendingSeason;
  final int undoSkipped;
  final String? syncStatus;

  String? get statusLabel => switch (status) {
    'watching' =>
      coverage && next == null && watched > 0 && watched == released
          ? 'Caught up'
          : 'Watching',
    'completed' => 'Completed',
    'on_hold' => 'On Hold',
    'dropped' => 'Dropped',
    _ => null,
  };
}

typedef Viewing = ({String id, String? day, int revision, String loggedAt});
typedef NextEpisode = ({
  String id,
  int revision,
  String title,
  int season,
  int number,
});
typedef LibraryEntry = ({
  CatalogTitle title,
  String activityAt,
  TrackingState? progress,
  String? sortText,
  num? sortValue,
  int? rating,
  String? watchedOn,
});

class TrackingCommand {
  TrackingCommand(this.titleId, this.action, this.payload)
    : id = const Uuid().v4(),
      submittedAt = DateTime.now().toUtc().toIso8601String();

  TrackingCommand.fromMap(Map<String, dynamic> row)
    : id = row['operation_id'] as String,
      submittedAt = row['submitted_at'] as String,
      titleId = row['title_id'] as String,
      action = row['action'] as String,
      payload = row['payload'] as Map<String, dynamic>;

  final String id;
  final String submittedAt;
  final String titleId;
  final String action;
  final Map<String, Object?> payload;

  Map<String, dynamic> toMap() => {
    'operation_id': id,
    'submitted_at': submittedAt,
    'title_id': titleId,
    'action': action,
    'payload': payload,
  };
}

class TrackingFailure implements Exception {
  const TrackingFailure(this.message);

  final String message;
}

class LibraryRepository {
  LibraryRepository(this.client, this.store);

  final SupabaseClient client;
  final OfflineStore store;
  final _busy = <(String, String)>{};
  final _changed = StreamController<void>.broadcast();

  Stream<void> get changes => _changed.stream;

  Future<void> dispose() => _changed.close();

  String _owner() =>
      client.auth.currentUser?.id ??
      (throw const TrackingFailure('Sign in to view your library.'));

  void notifyChanged() => _notify();

  void _notify() {
    if (!_changed.isClosed) _changed.add(null);
  }

  void _checkOwner(String owner) {
    if (client.auth.currentUser?.id != owner) {
      throw const TrackingFailure('Your session changed. Sign in again.');
    }
  }

  Future<Map<String, dynamic>> _confirmed(String owner, String titleId) =>
      store.cached(owner, 'tracking:$titleId', () async {
        _checkOwner(owner);
        final row = await client
            .schema('api')
            .rpc('tracking_snapshot', params: {'title_id': titleId});
        _checkOwner(owner);
        return row as Map<String, dynamic>;
      }, fallback: (value) => value as Map<String, dynamic>);

  Future<TrackingState> snapshot(String titleId) async {
    final owner = _owner();
    final queued =
        await store.read(owner, 'outbox', titleId) as Map<String, dynamic>?;
    if (queued != null && queued['sync'] != 'conflict') {
      return TrackingState.fromMap(
        queued['projection'] as Map<String, dynamic>,
      );
    }
    final row = await _confirmed(owner, titleId);
    return TrackingState.fromMap({
      ...row,
      if (queued != null) 'local_sync': 'conflict',
    });
  }

  Future<Map<int, Set<String>>> marks(List<CatalogTitle> titles) async {
    if (titles.isEmpty || client.auth.currentUser == null) return {};
    final rows =
        await client
                .schema('api')
                .rpc(
                  'my_title_marks',
                  params: {
                    'tmdb_ids': [for (final title in titles) title.tmdbId],
                  },
                )
            as List<dynamic>;
    return {
      for (final row in rows.cast<Map<String, dynamic>>())
        if (titles.any(
          (t) => t.tmdbId == row['tmdb_id'] && t.kind.name == row['kind'],
        ))
          row['tmdb_id'] as int: {
            ...(row['marks'] as List<dynamic>).cast<String>(),
          },
    };
  }

  Future<void> rememberTitle(CatalogTitle title) async {
    final owner = _owner();
    await store
        .write(owner, 'cache', 'title:${title.id}', title.toMap())
        .catchError((Object _) {});
  }

  Future<List<({TrackingCommand command, bool conflict})>>
  pendingChanges() async => (await store.queued(_owner()))
      .map(
        (row) => (
          command: TrackingCommand.fromMap(row),
          conflict: row['sync'] == 'conflict',
        ),
      )
      .toList();

  Future<void> discardConflict(String titleId) async {
    final owner = _owner();
    final pending =
        await store.read(owner, 'outbox', titleId) as Map<String, dynamic>?;
    if (pending?['sync'] == 'conflict') {
      await store.remove(owner, 'outbox', titleId);
      _notify();
    }
  }

  Future<void> sync(String owner) async {
    final items = await store.queued(owner);
    for (final item in items) {
      if (client.auth.currentUser?.id != owner) return;
      if (item['sync'] == 'conflict') continue;
      final command = TrackingCommand.fromMap(item);
      final key = (owner, command.titleId);
      if (!_busy.add(key)) continue;
      try {
        var current = await store.read(
          owner,
          'outbox',
          command.titleId,
        ) as Map<String, dynamic>?;
        if (current?['operation_id'] != command.id ||
            current?['sync'] == 'conflict') {
          continue;
        }
        while (current != null) {
          final next = TrackingCommand.fromMap(current);
          try {
            await _submit(owner, next);
          } on Exception catch (error) {
            if (client.auth.currentUser?.id != owner ||
                transientReadFailure(error)) {
              return;
            }
            if (error is! TrackingFailure && error is! PostgrestException) {
              rethrow;
            }
            await store.write(owner, 'outbox', command.titleId, {
              ...current,
              'sync': 'conflict',
            });
            _notify();
            break;
          }
          final tail = (current['tail'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          if (tail.isEmpty) {
            await store.remove(owner, 'outbox', command.titleId);
            current = null;
          } else {
            current = {
              ...tail.first,
              'tail': tail.skip(1).toList(),
              'projection': current['projection'],
            };
            await store.write(owner, 'outbox', command.titleId, current);
          }
          _notify();
        }
      } on Exception catch (error) {
        if (client.auth.currentUser?.id != owner ||
            transientReadFailure(error)) {
          return;
        }
        rethrow;
      } finally {
        _busy.remove(key);
      }
    }
  }

  Future<Map<String, dynamic>> preview(
    String titleId,
    String scope, {
    String? seasonId,
    String? episodeId,
  }) {
    final owner = _owner();
    return store.cached(
      owner,
      'batch:$titleId:$scope:$seasonId:$episodeId',
      () async {
        _checkOwner(owner);
        final result =
            await client
                    .schema('api')
                    .rpc(
                      'tracking_preview',
                      params: {
                        'title_id': titleId,
                        'scope': scope,
                        'season_id': ?seasonId,
                        'episode_id': ?episodeId,
                      },
                    )
                as Map<String, dynamic>;
        _checkOwner(owner);
        return result;
      },
      fallback: (saved) => saved as Map<String, dynamic>,
    );
  }

  Future<({List<LibraryEntry> entries, LibraryEntry? cursor, bool offline})>
  list(
    LibrarySection section, {
    MediaKind? media,
    LibraryEntry? after,
    LibrarySort sort = LibrarySort.activity,
    String? genre,
    int? minimumRating,
    String? status,
  }) async {
    final owner = _owner();
    var offline = false;
    final cached = await store.cached(
      owner,
      'library:${section.name}:${media?.name}:${sort.name}:$genre:$minimumRating:$status:${after?.title.id}:${after?.sortValue}',
      () async {
        _checkOwner(owner);
        final result =
            await client
                    .schema('api')
                    .rpc(
                      'library_page_v2',
                      params: {
                        'section': switch (section) {
                          LibrarySection.wanted => 'wanted',
                          LibrarySection.watchedMovies => 'watched_movies',
                          LibrarySection.watchedShows => 'watched_shows',
                        },
                        if (media != null) 'media': media.name,
                        'sort': sort.name,
                        'genre': ?genre,
                        'minimum_rating': ?minimumRating,
                        'status_filter': ?status,
                        if (after != null) 'before_title': after.title.id,
                        if (after != null) 'before_text': after.sortText,
                        if (after != null) 'before_value': after.sortValue,
                      },
                    )
                as List;
        _checkOwner(owner);
        for (final row in result) {
          final data = row['title'] as Map<String, dynamic>;
          await store
              .write(owner, 'cache', 'title:${data['id']}', data)
              .catchError((Object _) {});
          if (data['progress'] case final Map<String, dynamic> progress) {
            await store
                .write(owner, 'cache', 'tracking:${data['id']}', progress)
                .catchError((Object _) {});
          }
        }
        return result;
      },
      fallback: (value) {
        offline = true;
        return value as List;
      },
    );
    final rows = [...cached];
    final queued = await store.queued(owner);
    for (final pending in queued) {
      if (pending['sync'] == 'conflict') continue;
      final id = pending['title_id'];
      final local = pending['projection'] as Map<String, dynamic>;
      final selected = switch (section) {
        LibrarySection.wanted => local['wanted'] == true,
        LibrarySection.watchedMovies => local['viewing_count'] as int > 0,
        LibrarySection.watchedShows => local['intent'] != null,
      };
      final index = rows.indexWhere((row) => row['title']['id'] == id);
      if (index >= 0) {
        if (selected) {
          final row = rows[index] as Map<String, dynamic>;
          rows[index] = {
            ...row,
            'title': {
              ...row['title'] as Map<String, dynamic>,
              'progress': local,
            },
          };
        } else {
          rows.removeAt(index);
        }
      } else if (selected &&
          after == null &&
          status == null &&
          minimumRating == null &&
          genre == null) {
        final data = await store.read(
          owner,
          'cache',
          'title:$id',
        ) as Map<String, dynamic>?;
        if (data != null && (media == null || data['kind'] == media.name)) {
          rows.insert(0, {
            'title': {...data, 'progress': local},
            'activity_at': pending['submitted_at'],
          });
        }
      }
    }
    LibraryEntry entry(dynamic row) => (
      title: CatalogTitle.fromMap(row['title'] as Map<String, dynamic>),
      activityAt: row['activity_at'] as String,
      sortText: row['sort_text'] as String?,
      sortValue: row['sort_value'] as num?,
      rating: row['title']['personal_rating'] as int?,
      watchedOn: row['title']['last_watched_on'] as String?,
      progress: switch (row['title']['progress']) {
        final Map<String, dynamic> data => TrackingState.fromMap(data),
        _ => null,
      },
    );
    return (
      entries: rows.map(entry).toList(),
      cursor: cached.length == 20 ? entry(cached.last) : null,
      offline: offline,
    );
  }

  Future<List<Viewing>> history(String titleId, {Viewing? after}) async {
    final owner = _owner();
    final rows = await store.cached(
      owner,
      'history:$titleId:${after?.id}',
      () async {
        _checkOwner(owner);
        final result =
            await client
                    .schema('api')
                    .rpc(
                      'viewing_history_v2',
                      params: {
                        'title_id': titleId,
                        if (after != null) 'before_logged_at': after.loggedAt,
                        'before_day': ?after?.day,
                        if (after != null) 'before_id': after.id,
                      },
                    )
                as List;
        _checkOwner(owner);
        return result;
      },
      fallback: (value) => value as List,
    );
    return rows
        .map(
          (row) => (
            id: row['id'] as String,
            day: row['watched_on'] as String?,
            loggedAt: row['logged_at'] as String,
            revision: row['revision'] as int,
          ),
        )
        .toList();
  }

  Future<({TrackingState state, bool canUndo})> apply(
    TrackingCommand command,
  ) async {
    final result = await _save(command);
    _notify();
    return result;
  }

  Future<({TrackingState state, bool canUndo})> _submit(
    String owner,
    TrackingCommand command,
  ) async {
    _checkOwner(owner);
    final undo = command.action == 'undo';
    final row =
        await client
                .schema('api')
                .rpc(
                  undo ? 'undo_tracking' : 'apply_tracking',
                  params: undo
                      ? {
                          'operation_id': command.id,
                          'submitted_at': command.submittedAt,
                          'original_operation_id':
                              command.payload['original_operation_id'],
                        }
                      : command.toMap(),
                )
                .timeout(const Duration(seconds: 12))
            as Map<String, dynamic>;
    _checkOwner(owner);
    final state = _result(row);
    await store
        .write(owner, 'cache', 'tracking:${command.titleId}', row)
        .catchError((Object _) {});
    return (state: state, canUndo: row['can_undo'] == true);
  }

  Future<TrackingState> undo(TrackingCommand command) async =>
      (await apply(command)).state;

  Future<({TrackingState state, bool canUndo})> _save(
    TrackingCommand command,
  ) async {
    final owner = _owner();
    final title = command.titleId;
    final key = (owner, title);
    if (!_busy.add(key)) {
      throw const TrackingFailure('This title is already syncing.');
    }
    try {
      final current =
          await store.read(owner, 'outbox', title) as Map<String, dynamic>?;
      if (current != null) {
        final tail = (current['tail'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final touched = _touches(command);
        final overlaps = [current, ...tail].map(TrackingCommand.fromMap).any((
          old,
        ) {
          final prior = _touches(old);
          return prior.contains('*') ||
              touched.contains('*') ||
              prior.intersection(touched).isNotEmpty;
        });
        final projection = _project(
          current['projection'] as Map<String, dynamic>,
          command,
        );
        if (current['sync'] == 'conflict' ||
            overlaps ||
            projection == null ||
            tail.length >= 19) {
          throw const TrackingFailure(
            'Sync the earlier change for this title before making this edit.',
          );
        }
        _checkOwner(owner);
        await store.write(owner, 'outbox', title, {
          ...current,
          'projection': projection,
          'tail': [...tail, command.toMap()],
        });
        return (state: TrackingState.fromMap(projection), canUndo: false);
      }
      final previous = await store.read(
        owner,
        'cache',
        'tracking:$title',
      ) as Map<String, dynamic>?;
      final projection = previous == null ? null : _project(previous, command);
      if (projection == null || !store.available) {
        return await _submit(owner, command);
      }
      final item = {...command.toMap(), 'projection': projection};
      await store.write(owner, 'outbox', title, item);
      try {
        final result = await _submit(owner, command);
        await store.remove(owner, 'outbox', title);
        return result;
      } on Exception catch (error) {
        if (transientReadFailure(error) &&
            client.auth.currentUser?.id == owner) {
          return (state: TrackingState.fromMap(projection), canUndo: false);
        }
        if (client.auth.currentUser?.id == owner) {
          await store.remove(owner, 'outbox', title);
        }
        rethrow;
      }
    } finally {
      _busy.remove(key);
    }
  }

  Set<String> _touches(TrackingCommand command) => switch (command.action) {
    'set_wanted' || 'start_show' || 'set_show_intent' => {'tracking'},
    'mark_movie_watched' => {
      'tracking',
      'viewing:${command.payload['viewing_id']}',
    },
    'log_rewatch' ||
    'edit_movie_viewing' ||
    'delete_movie_viewing' => {'viewing:${command.payload['viewing_id']}'},
    'set_episode_watched' || 'edit_episode_watch_date' => {
      'episode:${command.payload['episode_id']}',
      if (command.payload.containsKey('show_revision')) 'tracking',
    },
    _ => {'*'},
  };

  Map<String, dynamic>? _project(
    Map<String, dynamic> row,
    TrackingCommand command,
  ) {
    final next = <String, dynamic>{...row, 'local_sync': 'pending'};
    final payload = command.payload;
    switch (command.action) {
      case 'set_wanted':
        next['wanted'] = payload['wanted'];
      case 'mark_movie_watched':
        next['wanted'] = false;
        next['viewing_count'] = 1;
      case 'log_rewatch':
        next['viewing_count'] = (row['viewing_count'] as int) + 1;
      case 'delete_movie_viewing':
        next['viewing_count'] = (row['viewing_count'] as int) - 1;
      case 'start_show':
      case 'set_show_intent':
        final intent = payload['intent'] ?? 'watching';
        next.addAll({'wanted': false, 'intent': intent, 'status': intent});
      case 'set_episode_watched':
        final watched = payload['watched'] == true;
        next['watched'] = (row['watched'] as int? ?? 0) + (watched ? 1 : -1);
        if (watched && row['intent'] == null) {
          next.addAll({
            'intent': 'watching',
            'status': 'watching',
            'wanted': false,
          });
        }
        if (watched && (row['next'] as Map?)?['id'] == payload['episode_id']) {
          next['next'] = null;
        }
      case 'edit_movie_viewing':
      case 'edit_episode_watch_date':
      case 'undo':
        break;
      case 'apply_show_batch':
        final count = (payload['episodes'] as List).length;
        final watched = row['watched'] as int? ?? 0;
        switch (payload['scope']) {
          case 'remove_show':
            next.addAll({
              'intent': null,
              'status': null,
              'watched': 0,
              'next': null,
              'seasons_completed': 0,
            });
          case 'mark_season_unwatched':
            next['watched'] = (watched - count).clamp(0, watched);
          default:
            next['watched'] = watched + count;
            if (row['intent'] == null && count > 0) {
              next.addAll({
                'intent': 'watching',
                'status': 'watching',
                'wanted': false,
              });
            }
        }
        next['next'] = null;
      default:
        return null;
    }
    return next;
  }

  TrackingState _result(Map<String, dynamic> result) =>
      switch (result['result']) {
        'applied' => TrackingState.fromMap(result),
        'conflict' => throw const TrackingFailure(
          'Your library changed on another device. Review the latest state.',
        ),
        'expired' => throw const TrackingFailure(
          'That change has expired. Try the action again.',
        ),
        _ => throw const TrackingFailure(
          'The change could not be saved. Try again.',
        ),
      };
}
