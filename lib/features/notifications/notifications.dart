import 'dart:async';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../firebase_options.dart';

typedef InboxItem = ({
  String id,
  String kind,
  String target,
  String eventAt,
  bool read,
  String? message,
});
typedef NoticePreference = ({bool inbox, bool push});

class InboxRepository {
  InboxRepository(this.client);
  final SupabaseClient client;

  Future<List<InboxItem>> items({InboxItem? after, String? id}) async {
    final rows =
        await client
                .schema('api')
                .rpc(
                  'inbox_page',
                  params: {
                    'before_time': ?after?.eventAt,
                    'before_id': ?after?.id,
                    'item_id': ?id,
                  },
                )
            as List;
    return rows
        .map(
          (row) => (
            id: row['id'] as String,
            kind: row['kind'] as String,
            target: row['target_id'] as String,
            eventAt: row['event_at'] as String,
            read: row['read_at'] != null,
            message: row['message'] as String?,
          ),
        )
        .toList();
  }

  Future<void> read({String? id, InboxItem? through}) async {
    await client
        .schema('api')
        .rpc(
          'mark_inbox_read',
          params: {
            'item_id': ?id,
            'through_time': ?through?.eventAt,
            'through_id': ?through?.id,
          },
        );
  }

  Future<Map<String, NoticePreference>> preferences() async {
    final row =
        await client.schema('api').rpc('notification_preferences')
            as Map<String, dynamic>;
    return row.map(
      (category, value) => MapEntry(category, (
        inbox: value['inbox'] == true,
        push: value['push'] == true,
      )),
    );
  }

  Future<void> setPreference(String category, NoticePreference value) async {
    await client
        .schema('api')
        .rpc(
          'set_notification_preferences',
          params: {
            'category_name': category,
            'inbox_enabled': value.inbox,
            'push_enabled': value.push,
          },
        );
  }
}

class AndroidPush {
  AndroidPush(this._inbox);

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static const _secure = FlutterSecureStorage();
  final InboxRepository _inbox;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  final _listeners = <StreamSubscription<dynamic>>[];
  Future<void>? _initializing;
  Future<void> _binding = Future.value();
  void Function(String)? _onOpen;
  String? _initialNotice;
  bool _attached = false;

  Future<void> _setup() =>
      _initializing ??= _initialize().onError<Object>((error, stack) {
        _initializing = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _initialize() async {
    if (!supported) return;
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.android);
    }
    final messaging = FirebaseMessaging.instance;
    if (_attached) return;
    _attached = true;
    _listeners.add(
      messaging.onTokenRefresh.listen(
        (token) =>
            unawaited(_queue(() => _register(token)).catchError((Object _) {})),
        onError: (Object _) {},
      ),
    );
    _listeners.add(
      FirebaseMessaging.onMessage.listen((_) {
        if (!_changes.isClosed) _changes.add(null);
      }, onError: (Object _) {}),
    );
    _listeners.add(
      FirebaseMessaging.onMessageOpenedApp.listen(
        _open,
        onError: (Object _) {},
      ),
    );
    final initial = await messaging.getInitialMessage();
    if (initial != null) _open(initial);
  }

  void _open(RemoteMessage message) {
    final id = message.data['notification_id'];
    if (id is! String || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) return;
    if (_onOpen == null) {
      _initialNotice = id;
    } else {
      _onOpen!(id);
    }
  }

  Future<void> attach(void Function(String) onOpen) async {
    _onOpen = onOpen;
    if (_initialNotice case final id?) {
      _initialNotice = null;
      onOpen(id);
    }
    try {
      await _setup();
    } on Exception {
      // In-app notifications remain available independently of FCM.
    }
  }

  Future<void> _queue(Future<void> Function() work) {
    final next = _binding.then((_) => work());
    _binding = next.catchError((Object _) {});
    return next;
  }

  Future<bool> requestPermission() async {
    if (!supported) return false;
    await _setup();
    final result = await FirebaseMessaging.instance.requestPermission();
    return result.authorizationStatus == AuthorizationStatus.authorized;
  }

  Future<void> refreshBinding() => _queue(() async {
    if (!supported || _inbox.client.auth.currentUser == null) return;
    await _setup();
    final preferences = await _inbox.preferences();
    final enabled = preferences.values.any(
      (value) => value.inbox && value.push,
    );
    final messaging = FirebaseMessaging.instance;
    if (!enabled ||
        (await messaging.getNotificationSettings()).authorizationStatus !=
            AuthorizationStatus.authorized) {
      await _detach(messaging, rotate: false);
      return;
    }
    final registration = await messaging.getToken();
    if (registration == null) {
      throw StateError('Android notification registration is unavailable.');
    }
    await _register(registration);
    await messaging.setAutoInitEnabled(true);
  });

  Future<void> _register(String token) async {
    final user = _inbox.client.auth.currentUser?.id;
    if (user == null) return;
    final settings = await _inbox.preferences();
    if (!settings.values.any((value) => value.inbox && value.push) ||
        _inbox.client.auth.currentUser?.id != user) {
      return;
    }
    var identity = await _secure.read(key: 'taspa.push.identity');
    if (identity == null) {
      final random = Random.secure();
      final key = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      identity = '${const Uuid().v4()}:$key';
      await _secure.write(key: 'taspa.push.identity', value: identity);
    }
    final binding = identity.split(':');
    if (_inbox.client.auth.currentUser?.id != user) return;
    await _inbox.client
        .schema('api')
        .rpc(
          'register_device',
          params: {
            'installation': binding.first,
            'binding_secret': binding.last,
            'registration_token': token,
          },
        );
  }

  Future<void> _detach(
    FirebaseMessaging messaging, {
    required bool rotate,
  }) async {
    final identity = await _secure.read(key: 'taspa.push.identity');
    try {
      if (identity != null && _inbox.client.auth.currentUser != null) {
        final binding = identity.split(':');
        await _inbox.client
            .schema('api')
            .rpc(
              'unregister_device',
              params: {
                'installation': binding.first,
                'binding_secret': binding.last,
              },
            );
      }
    } finally {
      await messaging.setAutoInitEnabled(false);
      if (rotate) await messaging.deleteToken();
    }
  }

  Future<void> beforeSignOut() => _queue(() async {
    if (!supported) return;
    await _setup();
    await _detach(FirebaseMessaging.instance, rotate: true);
  });

  Future<void> dispose() async {
    for (final listener in _listeners) {
      await listener.cancel();
    }
    await _changes.close();
  }
}
