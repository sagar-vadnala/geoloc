import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/data/delivery_api.dart';
import 'package:geoloc/feature/delivery/delivery_providers.dart';
import 'package:geoloc/feature/delivery/domain/delivery.dart';

import 'support.dart';

class _FlakyHistory extends SpyApi {
  _FlakyHistory(super.inner, {this.failures = 0});

  int failures;

  @override
  Future<HistoryPage> fetchHistory({String? cursor, int limit = 20}) {
    calls['fetchHistory'] = count('fetchHistory') + 1;
    if (failures-- > 0) {
      return Future.error(
        const DeliveryException(DeliveryErrorCode.network, retryable: true),
      );
    }
    return inner.fetchHistory(cursor: cursor, limit: limit);
  }
}

void main() {
  test('loads pages as the list scrolls and stops at the end', () {
    fakeAsync((async) {
      final now = async.getClock(DateTime.utc(2026, 11, 26, 9)).now;
      final api = _FlakyHistory(quietMock(now: now, seedHistory: true));
      final c = makeContainer(api: api, clock: now);
      c.listen(historyProvider, (_, _) {});
      async.flushMicrotasks();

      expect(c.read(historyProvider).items, hasLength(20));
      expect(c.read(historyProvider).hasMore, isTrue);

      final notifier = c.read(historyProvider.notifier);
      notifier.loadMore();
      notifier.loadMore(); // ignored while the first is loading
      async.flushMicrotasks();

      expect(api.count('fetchHistory'), 2);
      expect(c.read(historyProvider).items, hasLength(23));
      expect(c.read(historyProvider).hasMore, isFalse);

      notifier.loadMore();
      async.flushMicrotasks();
      expect(api.count('fetchHistory'), 2);
    });
  });

  test('a failed first load shows the error and can be retried', () {
    fakeAsync((async) {
      final now = async.getClock(DateTime.utc(2026, 11, 26, 9)).now;
      // Three failures exhaust the repository's automatic retries.
      final api = _FlakyHistory(
        quietMock(now: now, seedHistory: true),
        failures: 3,
      );
      final c = makeContainer(api: api, clock: now);
      c.listen(historyProvider, (_, _) {});
      async.flushMicrotasks();

      expect(c.read(historyProvider).error?.code, DeliveryErrorCode.network);
      expect(c.read(historyProvider).items, isEmpty);

      c.read(historyProvider.notifier).refresh();
      async.flushMicrotasks();
      expect(c.read(historyProvider).error, isNull);
      expect(c.read(historyProvider).items, hasLength(20));
    });
  });
}
