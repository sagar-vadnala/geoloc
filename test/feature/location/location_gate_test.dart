import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/core/theme.dart';
import 'package:geoloc/feature/location/presentation/location_gate.dart';
import 'package:geoloc/feature/location/providers.dart';
import 'package:geoloc/feature/location/services/location_permission_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class MockPermissionService extends Mock implements LocationPermissionService {}

void main() {
  late MockPermissionService permissions;

  Future<void> pumpGate(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          locationPermissionServiceProvider.overrideWithValue(permissions),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const LocationGate(child: Text('tracker')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    permissions = MockPermissionService();
    when(() => permissions.serviceChanges)
        .thenAnswer((_) => const Stream.empty());
    when(() => permissions.openAppSettings()).thenAnswer((_) async {});
    when(() => permissions.openLocationSettings()).thenAnswer((_) async {});
  });

  testWidgets('goes straight to the app when location is allowed', (
    tester,
  ) async {
    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.granted);

    await pumpGate(tester);

    expect(find.text('tracker'), findsOneWidget);
    verifyNever(() => permissions.request());
  });

  testWidgets('blocks the app until the user allows location', (tester) async {
    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.denied);
    when(() => permissions.request())
        .thenAnswer((_) async => LocationAccess.denied);

    await pumpGate(tester);

    expect(find.text('tracker'), findsNothing);
    expect(find.text('Geoloc needs your location'), findsOneWidget);

    when(() => permissions.request())
        .thenAnswer((_) async => LocationAccess.granted);
    await tester.tap(find.text('Allow location access'));
    await tester.pumpAndSettle();

    expect(find.text('tracker'), findsOneWidget);
  });

  testWidgets('points to Settings when the dialog can no longer be shown', (
    tester,
  ) async {
    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.deniedForever);

    await pumpGate(tester);
    await tester.tap(find.text('Open Settings'));

    expect(find.text('tracker'), findsNothing);
    verify(() => permissions.openAppSettings()).called(1);
  });

  testWidgets('asks to switch location on when it is off', (tester) async {
    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.serviceDisabled);

    await pumpGate(tester);
    await tester.tap(find.text('Turn on location'));

    verify(() => permissions.openLocationSettings()).called(1);
  });
}
