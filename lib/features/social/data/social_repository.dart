import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/backend_config.dart';

typedef SocialRow = Map<String, dynamic>;

class ImportFailure implements Exception {
  const ImportFailure(this.code, this.retryAfter);
  final String code;
  final int? retryAfter;
}

class SocialRepository {
  SocialRepository(this.client);
  final SupabaseClient client;
  SupabaseQuerySchema get _api => client.schema('api');

  Future<SocialRow?> one(String name, [SocialRow params = const {}]) async =>
      await _api.rpc(name, params: params) as SocialRow?;

  Future<List<SocialRow>> many(
    String name, [
    SocialRow params = const {},
  ]) async =>
      ((await _api.rpc(name, params: params)) as List).cast<SocialRow>();

  final _changed = StreamController<void>.broadcast();

  Stream<void> get changes => _changed.stream;
  void notifyChanged() => _changed.add(null);

  Future<void> change(String name, SocialRow params) async {
    await _api.rpc(name, params: params);
    _changed.add(null);
  }

  Map<String, String> get avatarHeaders => {
    'apikey': publishableKey,
    if (client.auth.currentSession case final session?)
      'Authorization': 'Bearer ${session.accessToken}',
  };

  Future<void> changeAvatar(Uint8List? png) async {
    final endpoint = Uri.parse('$backendUrl/functions/v1/avatar');
    final response = png == null
        ? await http.delete(endpoint, headers: avatarHeaders)
        : await http.post(
            endpoint,
            headers: {...avatarHeaders, 'Content-Type': 'image/png'},
            body: png,
          );
    if (response.statusCode != 200) {
      throw const FormatException('Avatar update is unavailable.');
    }
  }

  Future<SocialRow?> importStatus() => one('import_status');

  Future<SocialRow> importMust({String? username}) async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/functions/v1/must-import'),
          headers: {...avatarHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode(
            username == null
                ? {'action': 'step'}
                : {'action': 'start', 'username': username},
          ),
        )
        .timeout(const Duration(seconds: 60));
    final body = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as SocialRow;
    if (response.statusCode != 200) {
      throw ImportFailure(
        body['code'] as String? ?? 'import_unavailable',
        body['retry_after'] as int?,
      );
    }
    return body;
  }

  Future<List<SocialRow>> findPeople(String query) async {
    final prefix = query.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
    if (!RegExp(r'^[a-z0-9_]{2,24}$').hasMatch(prefix)) return [];
    return _api
        .from('profiles')
        .select('user_id,handle,display_name')
        .like('handle', "${prefix.replaceAll('_', r'\_')}%")
        .order('handle')
        .limit(20);
  }

  Future<List<SocialRow>> feed({SocialRow? after}) => many('following_feed', {
    'before_time': ?after?['created_at'],
    'before_id': ?after?['id'],
  });

  Future<List<SocialRow>> reviews({
    String? title,
    String? season,
    String? author,
    SocialRow? after,
  }) => many('opinion_page', {
    'title': ?title,
    'season': ?season,
    'author': ?author,
    'before_time': ?after?['published_at'],
    'before_id': ?after?['id'],
  });

  Future<SocialRow?> opinions(String title, String? season) =>
      one('title_opinions', {'title': title, 'season': ?season});

  Future<void> rate(
    String title,
    String? season,
    num? score,
    String audience,
    int revision,
    bool share,
  ) => change('set_rating', {
    'title': title,
    'season': season,
    'score_value': score,
    'audience_value': audience,
    'observed_revision': revision,
    'share': share,
  });

  Future<void> saveReview(
    String title,
    String? season,
    String content,
    bool spoiler,
    String audience,
    int revision,
  ) => change('save_review', {
    'title': title,
    'season': season,
    'content': content,
    'has_spoiler': spoiler,
    'audience_value': audience,
    'observed_revision': revision,
    'discussion': const Uuid().v4(),
  });
}
