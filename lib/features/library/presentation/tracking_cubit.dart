import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/library_repository.dart';

class TrackingCubit extends Cubit<TrackingState?> {
  TrackingCubit(this._repository, this.titleId) : super(null) {
    _changes = _repository.changes.listen((_) => unawaited(load().catchError((Object _) {})));
  }

  final LibraryRepository _repository;
  final String titleId;
  late final StreamSubscription<void> _changes;

  @override
  Future<void> close() async {
    await _changes.cancel();
    return super.close();
  }

  Future<void> load() async {
    final next = await _repository.snapshot(titleId);
    if (!isClosed) emit(next);
  }

  Future<bool> apply(TrackingCommand command) async {
    final result = await _repository.apply(command);
    if (!isClosed) emit(result.state);
    return result.canUndo;
  }

  Future<void> undo(TrackingCommand command) async {
    final result = await _repository.undo(command);
    if (!isClosed) emit(result);
  }
}

String trackingMessage(Object error) {
  if (error is TrackingFailure) return error.message;
  if (error is PostgrestException && error.code == '22023') {
    return 'This change is no longer available. Refresh and try again.';
  }
  return 'Could not save the change. Try again.';
}

bool isTrackingConflict(Object error) =>
    error is TrackingFailure ||
    (error is PostgrestException &&
        {'22023', '22007', '22P02', '23505', '42501'}.contains(error.code));

