import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/offline_store.dart';

enum AccountPhase { guest, loading, needsHandle, ready, recovery, unavailable }

typedef Account = ({AccountPhase phase, String? userId, String? handle});

class AccountCubit extends Cubit<Account> {
  AccountCubit(this._client, this._offline)
    : super((phase: AccountPhase.guest, userId: null, handle: null)) {
    _subscription = _client.auth.onAuthStateChange.listen(
      (change) {
        if (change.event == AuthChangeEvent.passwordRecovery) {
          _recovering = true;
        }
        final session = change.session;
        if (session == null) _recovering = false;
        if (session?.user.id != state.userId ||
            state.phase == AccountPhase.guest ||
            _recovering) {
          unawaited(_load(session));
        }
      },
      onError: (Object error, StackTrace stack) {
        if (state.phase == AccountPhase.loading) {
          emit((
            phase: AccountPhase.unavailable,
            userId: state.userId,
            handle: null,
          ));
        }
      },
    );
    unawaited(refresh());
  }

  final SupabaseClient _client;
  final OfflineStore _offline;
  late final StreamSubscription<AuthState> _subscription;
  bool _recovering = false;
  int _request = 0;

  Future<void> refresh() => _load(_client.auth.currentSession);

  Future<void> _load(Session? session) async {
    final request = ++_request;
    final id = session?.user.id;
    if (id == null || _recovering) {
      emit((
        phase: id == null ? AccountPhase.guest : AccountPhase.recovery,
        userId: id,
        handle: null,
      ));
      return;
    }
    emit((phase: AccountPhase.loading, userId: id, handle: null));
    try {
      final profile = await _offline.cached(id, 'account', () async {
        final profile = await _client
            .schema('api')
            .from('profiles')
            .select('handle')
            .eq('user_id', id)
            .maybeSingle();
        if (_client.auth.currentUser?.id != id) {
          throw StateError('Account changed');
        }
        return profile ?? <String, dynamic>{};
      }, fallback: (saved) => saved as Map<String, dynamic>);
      if (isClosed || request != _request) return;
      emit((
        phase: profile['handle'] == null
            ? AccountPhase.needsHandle
            : AccountPhase.ready,
        userId: id,
        handle: profile['handle'] as String?,
      ));
    } on Object {
      if (isClosed || request != _request) return;
      emit((phase: AccountPhase.unavailable, userId: id, handle: null));
    }
  }

  Future<void> claim(String handle) async {
    await _client
        .schema('api')
        .rpc('claim_profile', params: {'requested_handle': handle});
    await refresh();
  }

  Future<void> changePassword(String password) async {
    await _client.auth.updateUser(UserAttributes(password: password));
    _recovering = false;
    await refresh();
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    return super.close();
  }
}
