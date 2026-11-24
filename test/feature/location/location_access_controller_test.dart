import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/location/providers.dart';
import 'package:geoloc/feature/location/services/location_permission_service.dart';
import 'package:mocktail/mocktail.dart';

class MockPermissionService extends Mock implements LocationPermissionService {}

void main() {
  late MockPermissionService permissions;
  late ProviderContainer container;

  LocationAccess read() => container.read(locationAccessProvider);
  Future<void> refresh({bool ask = false}) =>
      container.read(locationAccessProvider.notifier).refresh(askIfNeeded: ask);

  setUp(() {
    permissions = MockPermissionService();
    when(() => permissions.openAppSettings()).thenAnswer((_) async {});
    when(() => permissions.openLocationSettings()).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        locationPermissionServiceProvider.overrideWithValue(permissions),
      ],
    );
    addTearDown(container.dispose);
  });

  test('starts in the checking state', () {
    expect(read(), LocationAccess.checking);
  });

  test('asks straight away on first launch and unlocks when allowed', () async {
    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.denied);
    when(() => permissions.request())
        .thenAnswer((_) async => LocationAccess.granted);

    await refresh(ask: true);

    expect(read(), LocationAccess.granted);
    verify(() => permissions.request()).called(1);
  });

  test('stays locked when the user says no', () async {
    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.denied);
    when(() => permissions.request())
        .thenAnswer((_) async => LocationAccess.denied);

    await refresh(ask: true);

    expect(read(), LocationAccess.denied);
  });

  test(
    'does not show the dialog when it was already answered for good',
    () async {
      when(() => permissions.check())
          .thenAnswer((_) async => LocationAccess.deniedForever);

      await refresh(ask: true);

      expect(read(), LocationAccess.deniedForever);
      verifyNever(() => permissions.request());
    },
  );

  test('a plain refresh never shows the dialog', () async {
    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.denied);

    await refresh();

    expect(read(), LocationAccess.denied);
    verifyNever(() => permissions.request());
  });

  test('refresh while the dialog is open is ignored', () async {
    final dialog = Completer<LocationAccess>();
    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.denied);
    when(() => permissions.request()).thenAnswer((_) => dialog.future);

    final first = refresh(ask: true);
    await pumpEventQueue();
    await refresh(); // e.g. app resumed because the dialog closed
    dialog.complete(LocationAccess.granted);
    await first;

    expect(read(), LocationAccess.granted);
    verify(() => permissions.check()).called(1);
  });

  test('settings button opens the screen that can fix the problem', () async {
    final controller = container.read(locationAccessProvider.notifier);

    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.serviceDisabled);
    await refresh();
    await controller.openSettings();
    verify(() => permissions.openLocationSettings()).called(1);

    when(() => permissions.check())
        .thenAnswer((_) async => LocationAccess.deniedForever);
    await refresh();
    await controller.openSettings();
    verify(() => permissions.openAppSettings()).called(1);
  });
}
