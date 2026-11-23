import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const backendUrl = String.fromEnvironment('SUPABASE_URL');
const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const _nativeAuthCallback = 'com.taspa.taspa://auth-callback';

String get authCallback =>
    kIsWeb ? Uri.base.resolve('/').toString() : _nativeAuthCallback;

Future<void> initializeBackend() async {
  final url = Uri.tryParse(backendUrl);
  if (url == null || !url.hasAuthority || publishableKey.isEmpty) {
    throw StateError('Provide the Supabase URL and publishable key.');
  }
  if (!publishableKey.startsWith('sb_publishable_') &&
      !(url.isScheme('http') &&
          {'localhost', '127.0.0.1', '10.0.2.2'}.contains(url.host))) {
    throw StateError('A hosted build requires a publishable key.');
  }
  if (!url.isScheme('https') &&
      !(url.isScheme('http') &&
          {'localhost', '127.0.0.1', '10.0.2.2'}.contains(url.host))) {
    throw StateError('Use an HTTPS Supabase URL.');
  }
  await Supabase.initialize(
    url: backendUrl,
    publishableKey: publishableKey,
    authOptions: kIsWeb
        ? const FlutterAuthClientOptions()
        : FlutterAuthClientOptions(
            localStorage: const _SessionStorage(),
            detectSessionInUriPredicate: (uri) =>
                uri.scheme == 'com.taspa.taspa' && uri.host == 'auth-callback',
          ),
  );
}

class _SessionStorage extends LocalStorage {
  const _SessionStorage();
  static const _storage = FlutterSecureStorage();
  static final _key = 'taspa.session.${Uri.parse(backendUrl).host}';

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() => _storage.read(key: _key);

  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
