import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/core/theme.dart';
import 'package:geoloc/feature/delivery/data/delivery_api.dart';
import 'package:geoloc/feature/delivery/data/delivery_repository.dart';
import 'package:geoloc/feature/delivery/data/mock/mock_delivery_api.dart';
import 'package:geoloc/feature/delivery/delivery_providers.dart';
import 'package:geoloc/feature/delivery/domain/delivery_status.dart';
import 'package:geoloc/feature/delivery/presentation/dashboard_screen.dart';
import 'package:geoloc/feature/delivery/presentation/verify_delivery_screen.dart';
import 'package:geoloc/feature/location/providers.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

List<Override> overridesFor(MockDeliveryApi mock, FakeLocations locations) => [
  deliveryConfigProvider.overrideWithValue(testConfig),
  deliveryApiProvider.overrideWithValue(mock),
  mockDeliveryApiProvider.overrideWithValue(mock),
  deliveryRepositoryProvider.overrideWith(
    (ref) => DeliveryRepository(mock, sleep: (_) async {}),
  ),
  deliveryLocationSourceProvider.overrideWithValue(locations.call),
  // The connectivity plugin has no implementation in widget tests.
  isOnlineProvider.overrideWith((ref) => Stream.value(true)),
];

Widget app(List<Override> overrides, Widget home) => ProviderScope(
  overrides: overrides,
  retry: (_, _) => null,
  child: MaterialApp(theme: AppTheme.light(), home: home),
);

void main() {
  testWidgets('going online shows a request with only the drop-off area', (
    tester,
  ) async {
    final mock = quietMock(now: DateTime.now);
    await tester.pumpWidget(
      app(overridesFor(mock, FakeLocations()), const DashboardScreen()),
    );
    await tester.pump();

    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Requests'), findsNothing);

    await tester.tap(find.text('Go online'));
    await tester.pump();
    await tester.pump();

    expect(find.text("You're online"), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Exact address shown after you accept'), findsOneWidget);

    // Dispose the scope so polling timers stop before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a wrong delivery code shows the attempts left', (tester) async {
    final mock = quietMock(now: DateTime.now);
    var n = 0;
    String key() => 'k${n++}';
    await mock.setAvailability(online: true, idempotencyKey: key());
    final offer = (await mock.fetchOffers()).offers.single;
    await mock.accept(offer.id, idempotencyKey: key());
    await mock.reportArrival(
      offer.id,
      const ArrivalReport(
        stop: StopKind.pickup,
        detection: ArrivalDetection.manual,
      ),
      idempotencyKey: key(),
    );
    await mock.confirmPickup(offer.id, idempotencyKey: key());
    await mock.reportArrival(
      offer.id,
      const ArrivalReport(
        stop: StopKind.dropoff,
        detection: ArrivalDetection.manual,
      ),
      idempotencyKey: key(),
    );
    final right = mock.debugOtp(offer.id)!;
    final wrong = right == '1111' ? '2222' : '1111';

    await tester.pumpWidget(
      app(overridesFor(mock, FakeLocations()), const VerifyDeliveryScreen()),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('4-digit code'), findsOneWidget);
    expect(
      find.text("Demo mode: the recipient's code is $right."),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), wrong);
    await tester.pump();
    await tester.tap(find.text('Complete delivery'));
    await tester.pump();
    await tester.pump();

    expect(find.text("That code didn't match. 4 tries left."), findsOneWidget);
    expect((await mock.fetchActive())?.status, DeliveryStatus.atDropoff);

    await tester.pumpWidget(const SizedBox());
  });
}
