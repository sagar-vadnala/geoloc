import 'package:riverpod/riverpod.dart';

import '../data/delivery_api.dart';
import '../delivery_providers.dart';
import '../domain/delivery.dart';

class HistoryState {
  const HistoryState({
    this.items = const [],
    this.nextCursor,
    this.loadingFirst = false,
    this.loadingMore = false,
    this.loaded = false,
    this.error,
  });

  final List<Delivery> items;
  final String? nextCursor;
  final bool loadingFirst;
  final bool loadingMore;

  /// At least one page has been received.
  final bool loaded;
  final DeliveryException? error;

  bool get hasMore => nextCursor != null;
}

/// Cursor-paginated history: the first page on open, more as the list
/// scrolls. Only what is on screen is kept in memory; nothing is persisted.
class HistoryController extends Notifier<HistoryState> {
  static const pageSize = 20;

  @override
  HistoryState build() {
    Future.microtask(refresh);
    return const HistoryState(loadingFirst: true);
  }

  Future<void> refresh() async {
    if (!ref.mounted) return;
    state = HistoryState(
      items: state.items,
      nextCursor: state.nextCursor,
      loaded: state.loaded,
      loadingFirst: true,
    );
    try {
      final page = await ref
          .read(deliveryRepositoryProvider)
          .history(limit: pageSize);
      if (!ref.mounted) return;
      state = HistoryState(
        items: page.items,
        nextCursor: page.nextCursor,
        loaded: true,
      );
    } on DeliveryException catch (e) {
      if (!ref.mounted) return;
      state = HistoryState(
        items: state.items,
        nextCursor: state.nextCursor,
        loaded: state.loaded,
        error: e,
      );
    }
  }

  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null || state.loadingMore || state.loadingFirst) return;
    state = HistoryState(
      items: state.items,
      nextCursor: cursor,
      loaded: true,
      loadingMore: true,
    );
    try {
      final page = await ref
          .read(deliveryRepositoryProvider)
          .history(cursor: cursor, limit: pageSize);
      if (!ref.mounted) return;
      final seen = {for (final d in state.items) d.id};
      state = HistoryState(
        items: [
          ...state.items,
          ...page.items.where((d) => !seen.contains(d.id)),
        ],
        nextCursor: page.nextCursor,
        loaded: true,
      );
    } on DeliveryException catch (e) {
      if (!ref.mounted) return;
      state = HistoryState(
        items: state.items,
        nextCursor: cursor,
        loaded: true,
        error: e,
      );
    }
  }
}
