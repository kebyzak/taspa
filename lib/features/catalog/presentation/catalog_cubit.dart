import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/catalog_repository.dart';

typedef ShelfState = ({CatalogPage? page, bool loading, bool failed});

class CatalogCubit extends Cubit<ShelfState> {
  CatalogCubit(this._repository, {this.kind, this.shelf = BrowseShelf.trending, this.genre})
    : super((page: null, loading: false, failed: false));

  final CatalogRepository _repository;
  final MediaKind? kind;
  final BrowseShelf shelf;
  final int? genre;
  int _request = 0;
  String? _query;

  Future<void> load({String? query, bool more = false}) async {
    if (more && (state.loading || state.page?.nextPage == null)) return;
    final request = ++_request;
    final previous = query == _query ? state.page : null;
    _query = query;
    emit((page: previous, loading: true, failed: false));
    try {
      final result = await _repository.list(
        kind: kind,
        query: query,
        shelf: shelf,
        genre: genre,
        page: more ? previous!.nextPage! : 1,
      );
      if (isClosed || request != _request) return;
      emit((
        page: more
            ? (
                items: [...previous!.items, ...result.items],
                people: [...previous.people,...result.people],
                nextPage: result.nextPage,
                stale: previous.stale || result.stale,
              )
            : result,
        loading: false,
        failed: false,
      ));
    } on Exception {
      if (isClosed || request != _request) return;
      emit((page: previous, loading: false, failed: true));
    }
  }

  void clear() {
    _request++;
    _query = null;
    emit((page: null, loading: false, failed: false));
  }
}
